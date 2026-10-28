import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/ocr_service.dart';

/// Geometric parser for the supplied seven-column delivery template.
/// No arithmetic on "difference" and no conversion of supplier codes to EAN.
class DeliveryTableParser {
  double _median(Iterable<double> values) {
    final sorted = values.toList()..sort();
    return sorted[sorted.length ~/ 2];
  }

  TableParseResult parse(List<OcrWord> words, int imageWidth) {
    words = words.where((word) => word.text.trim().isNotEmpty).toList();
    final units = words
        .where(
          (w) => RegExp(r'^[бп]?рой[кн]а[.,]?$').hasMatch(w.text.toLowerCase()),
        )
        .toList();
    if (units.length < 2 && imageWidth > 0) return _fiveColumns(words);
    if (imageWidth <= 0) {
      return TableParseResult(
        [],
        'Таблицата не е разпозната уверено. '
        'Снимайте отново с видими колони или добавете позиция ръчно.',
      );
    }
    final unitLeft = _median(units.map((w) => w.left));
    final height = _median(units.map((w) => w.height));
    final unitRight = _median(units.map((w) => w.right));
    final codes = words
        .where(
          (w) =>
              w.right < unitLeft * .55 &&
              RegExp(r'^[\dA-Za-zА-Яа-я‘\x27]{7,12}$').hasMatch(w.text) &&
              RegExp(r'\d{3}').hasMatch(w.text),
        )
        .toList();
    // Align endpoints first; a global slope search can align adjacent rows.
    units.sort((a, b) => a.y.compareTo(b.y));
    codes.sort((a, b) => a.y.compareTo(b.y));
    double endpointSlope(bool bottom) {
      final count = [
        codes.length,
        units.length,
        3,
      ].reduce((a, b) => a < b ? a : b);
      if (count == 0) return 0;
      return _median(
        List.generate(count, (index) {
          final code = codes[bottom ? codes.length - 1 - index : index];
          final unit = units[bottom ? units.length - 1 - index : index];
          return ((unit.y - code.y) / (unit.x - code.x))
              .clamp(-.1, .1)
              .toDouble();
        }),
      );
    }

    final topSlope = endpointSlope(false);
    final bottomSlope = endpointSlope(true);
    final lines = <int, List<OcrWord>>{};
    for (final word in words) {
      if (word.line != null &&
          word.y > units.first.y - height * 2 &&
          word.height >= height * .4 &&
          word.height <= height * 1.8) {
        lines.putIfAbsent(word.line!, () => []).add(word);
      }
    }
    final slopeSamples = <({double y, double slope})>[];
    for (final line in lines.values) {
      if (line.length < 4) continue;
      final slopes = <double>[];
      for (var i = 0; i < line.length; i++) {
        for (var j = i + 1; j < line.length; j++) {
          final dx = line[j].x - line[i].x;
          if (dx.abs() > imageWidth * .25) {
            final slope = (line[j].y - line[i].y) / dx;
            if (slope.abs() < .12) slopes.add(slope);
          }
        }
      }
      if (slopes.isEmpty) continue;
      final slope = _median(slopes);
      final intercept = _median(line.map((w) => w.y - slope * w.x));
      final residual = _median(
        line.map((w) => (w.y - slope * w.x - intercept).abs()),
      );
      if (residual < height * .5) {
        slopeSamples.add((y: _median(line.map((w) => w.y)), slope: slope));
      }
    }
    double rowY(OcrWord w) {
      if (slopeSamples.length >= 3) {
        final nearby = slopeSamples.toList()
          ..sort((a, b) => (a.y - w.y).abs().compareTo((b.y - w.y).abs()));
        final slope = _median(nearby.take(5).map((s) => s.slope));
        return w.y - slope * w.x;
      }
      final span = units.last.y - units.first.y;
      final fraction = span == 0
          ? 0
          : ((w.y - units.first.y) / span).clamp(0, 1);
      return w.y - (topSlope + (bottomSlope - topSlope) * fraction) * w.x;
    }

    final anchors = units.map(rowY).toList()..sort();
    // Missing unit recognition must not discard an otherwise visible code row.
    for (final code in codes) {
      if (anchors.every((y) => (y - rowY(code)).abs() > height * .8)) {
        anchors.add(rowY(code));
      }
    }
    anchors.sort();
    final firstRow = anchors.first;
    final lastRow = anchors.last;
    final left = codes.isEmpty
        ? imageWidth * .06
        : _median(codes.map((c) => c.left));
    final nameLeft = left + (unitLeft - left) * .23;
    final quantityLeft = unitLeft - height * 3.4;
    final expiryLeft = unitRight + height * .25;
    final dateWords = words
        .where(
          (w) =>
              w.left > expiryLeft &&
              w.left < imageWidth * .8 &&
              RegExp(r'^\d{2}\.\d{2}\.\d{4}$').hasMatch(w.text),
        )
        .toList();
    final lotLeft = dateWords.isEmpty
        ? expiryLeft + height * 5.7
        : _median(dateWords.map((w) => w.right)) + height * .1;
    final differenceLeft = lotLeft + height * 8;
    final boundaries = [
      nameLeft,
      quantityLeft,
      unitLeft - height * .2,
      expiryLeft,
      lotLeft,
      differenceLeft,
    ];
    final rows = List.generate(
      anchors.length,
      (_) => List.generate(7, (_) => <OcrWord>[]),
    );
    for (final word in words) {
      final y = rowY(word);
      if (y < firstRow - height || y > lastRow + height) continue;
      var nearest = 0;
      for (var i = 1; i < anchors.length; i++) {
        if ((anchors[i] - y).abs() < (anchors[nearest] - y).abs()) nearest = i;
      }
      if ((anchors[nearest] - y).abs() > height * .85) continue;
      final nearestUnit = units.reduce(
        (a, b) =>
            (rowY(a) - anchors[nearest]).abs() <
                (rowY(b) - anchors[nearest]).abs()
            ? a
            : b,
      );
      final horizontalShift = nearestUnit.left - unitLeft;
      var column = boundaries.indexWhere(
        (boundary) => word.x < boundary + horizontalShift,
      );
      if (column == -1) column = 6;
      rows[nearest][column].add(word);
    }
    final items = <DraftItem>[];
    const fields = [
      'supplierCode',
      'name',
      'ordered',
      'unit',
      'expiry',
      'lot',
      'difference',
    ];
    for (final row in rows) {
      final raw = <String, String>{};
      final uncertain = <String>[];
      for (var c = 0; c < row.length; c++) {
        row[c].sort((a, b) => a.left.compareTo(b.left));
        raw[fields[c]] = row[c].map((w) => w.text).join(' ').trim();
        if (row[c].isEmpty || row[c].any((w) => w.confidence < 85)) {
          uncertain.add(fields[c]);
        }
      }
      // A visible article row must survive even if OCR lost its name. Keep the
      // blank/raw name for manual/catalog selection instead of losing stock rows.
      if (raw['name']!.length < 3) {
        if (raw['supplierCode']!.isEmpty) continue;
        uncertain.add('name');
      }
      if (parseDocumentDate(raw['expiry']!) == null) uncertain.add('expiry');
      if (raw['lot']!.isEmpty || raw['lot'] == '1') uncertain.add('lot');
      if (parseQuantity(raw['ordered']!) == null) uncertain.add('ordered');
      // Keep original OCR evidence, including unit and document difference.
      uncertain.removeWhere(
        (field) => !DraftItem.visibleFields.contains(field),
      );
      items.add(
        DraftItem(
          supplierCode: raw['supplierCode']!,
          name: raw['name']!,
          unit: raw['unit'] ?? '',
          ordered: raw['ordered']!,
          expiry: raw['expiry']!,
          lot: raw['lot']!,
          received: parseQuantity(raw['ordered']!) == null
              ? ''
              : raw['ordered']!,
          original: raw,
          uncertainFields: uncertain.toSet().toList(),
        ),
      );
    }
    return TableParseResult(
      items,
      'Колоните са изведени по позициите на думите. '
      'Приети е попълнено от Заявени и изисква физическо потвърждение.',
    );
  }

  bool mayBeDuplicate(DraftPage first, DraftPage second) {
    if (first.imageHash.isNotEmpty && first.imageHash == second.imageHash) {
      return true;
    }
    final a = first.items.map((i) => normalizedProductName(i.name)).toSet();
    final b = second.items.map((i) => normalizedProductName(i.name)).toSet();
    if (a.length < 5 || b.length < 5) return false;
    final tokensA = a
        .expand((name) => name.split(RegExp(r'[^a-zа-яё0-9]+')))
        .where((t) => t.length >= 4)
        .toSet();
    final tokensB = b
        .expand((name) => name.split(RegExp(r'[^a-zа-яё0-9]+')))
        .where((t) => t.length >= 4)
        .toSet();
    // Whole-name agreement is a second signal when words contain punctuation.
    return a.intersection(b).length / a.union(b).length > .4 ||
        (tokensA.isNotEmpty &&
            tokensB.isNotEmpty &&
            tokensA.intersection(tokensB).length /
                    tokensA.union(tokensB).length >
                .55);
  }

  TableParseResult _fiveColumns(List<OcrWord> words) {
    const names = ['артикул', 'наимен', 'заяв', 'годност', 'партид'];
    final headers = <OcrWord>[];
    for (final name in names) {
      final candidates = words.where(
        (w) => w.text.toLowerCase().contains(name),
      );
      if (candidates.isEmpty) {
        return TableParseResult(
          [],
          'Таблицата не е разпозната: неясни колони. Снимайте отново или добавете позиция ръчно.',
        );
      }
      headers.add(candidates.first);
    }
    if (headers.indexed.any(
      (entry) => entry.$1 > 0 && entry.$2.left <= headers[entry.$1 - 1].left,
    )) {
      return TableParseResult([], 'Подредбата на колоните не е разпозната.');
    }
    final slope =
        (headers.last.y - headers.first.y) / (headers.last.x - headers.first.x);
    double rowY(OcrWord w) => w.y - slope * w.x;
    final headerY = _median(headers.map(rowY));
    final height = _median(headers.map((w) => w.height));
    final anchors =
        words
            .where(
              (w) =>
                  w.left < headers[1].left - height &&
                  rowY(w) > headerY + height &&
                  RegExp(r'\d').hasMatch(w.text),
            )
            .toList()
          ..sort((a, b) => rowY(a).compareTo(rowY(b)));
    final grouped = <List<OcrWord>>[];
    for (final anchor in anchors) {
      if (grouped.isEmpty ||
          (rowY(anchor) - rowY(grouped.last.first)).abs() > height) {
        grouped.add([]);
      }
      grouped.last.add(anchor);
    }
    final items = <DraftItem>[];
    const fields = ['supplierCode', 'name', 'ordered', 'expiry', 'lot'];
    for (final group in grouped) {
      final y = rowY(group.first);
      final cells = List.generate(5, (_) => <OcrWord>[]);
      for (final w in words) {
        if ((rowY(w) - y).abs() > height * .85) continue;
        final column = headers
            .skip(1)
            .toList()
            .indexWhere((h) => w.x < h.left - height * .4);
        cells[column < 0 ? 4 : column].add(w);
      }
      final raw = <String, String>{};
      final uncertain = <String>[];
      for (var i = 0; i < 5; i++) {
        cells[i].sort((a, b) => a.left.compareTo(b.left));
        raw[fields[i]] = cells[i].map((w) => w.text).join(' ');
        if (cells[i].isEmpty || cells[i].any((w) => w.confidence < 85)) {
          uncertain.add(fields[i]);
        }
      }
      if (raw['name']!.isEmpty) continue;
      if (parseDocumentDate(raw['expiry']!) == null) uncertain.add('expiry');
      if (parseQuantity(raw['ordered']!) == null) uncertain.add('ordered');
      items.add(
        DraftItem(
          supplierCode: raw['supplierCode']!,
          name: raw['name']!,
          unit: raw['unit'] ?? '',
          ordered: raw['ordered']!,
          received: parseQuantity(raw['ordered']!) == null
              ? ''
              : raw['ordered']!,
          expiry: raw['expiry']!,
          lot: raw['lot']!,
          original: raw,
          uncertainFields: uncertain,
        ),
      );
    }
    return TableParseResult(
      items,
      'Приети е предварително попълнено. Потвърдете след физическа проверка.',
    );
  }
}
