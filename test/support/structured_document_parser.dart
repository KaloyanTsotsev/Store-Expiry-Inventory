import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/gtin.dart';
import 'package:expiry_tracker/services/ocr_service.dart';

import 'legacy_delivery_parser.dart';

/// Conservative header-driven document structuring. No generated values.
/// The established geometric parser remains the first choice for its template.
class StructuredDocumentParser {
  final legacy = DeliveryTableParser();
  static const headers = <String, String>{
    'name': r'^(наимен|описание|продукт|description|product)',
    'barcode': r'^(баркод|ean|gtin|barcode)',
    'supplierCode': r'^(артикул|код|code|sku)',
    'ordered': r'^(количество|к-во|кол-во|заявени|qty|quantity)',
    'unit': r'^(мярка|ед[.]?изм|unit|uom)',
    'expiry': r'^(годност|годен|срок|expiry|expires|best)',
    'lot': r'^(партида|lot|batch)',
  };

  TableParseResult parse(List<OcrWord> words, int width) {
    words = words.where((word) => word.text.trim().isNotEmpty).toList();
    final original = legacy.parse(words, width);
    // Explicit barcode columns require the generic parser, otherwise old
    // supplier article columns could be misread as EAN.
    if (original.items.isNotEmpty &&
        !words.any(
          (w) => RegExp(
            headers['barcode']!,
            caseSensitive: false,
          ).hasMatch(w.text),
        )) {
      return original;
    }
    final candidates = words
        .where(
          (w) => headers.values.any(
            (pattern) => RegExp(pattern, caseSensitive: false).hasMatch(w.text),
          ),
        )
        .toList();
    Map<String, OcrWord> best = {};
    for (final anchor in candidates) {
      final row = <String, OcrWord>{};
      for (final word in candidates.where(
        (w) => (w.y - anchor.y).abs() <= anchor.height * 1.2,
      )) {
        for (final entry in headers.entries) {
          if (RegExp(entry.value, caseSensitive: false).hasMatch(word.text)) {
            row.putIfAbsent(entry.key, () => word);
          }
        }
      }
      if (row.length > best.length && row.containsKey('name')) best = row;
    }
    if (best.length < 2 ||
        (!best.containsKey('ordered') &&
            !best.containsKey('supplierCode') &&
            !best.containsKey('barcode'))) {
      return original;
    }
    final columns = best.entries.toList()
      ..sort((a, b) => a.value.left.compareTo(b.value.left));
    final height = (best.values.map((w) => w.height).toList()
      ..sort())[best.length ~/ 2];
    final first = columns.first.value, last = columns.last.value;
    final slope = last.x == first.x
        ? 0.0
        : ((last.y - first.y) / (last.x - first.x)).clamp(-.15, .15).toDouble();
    double y(OcrWord w) => w.y - slope * w.x;
    final headerY = best.values.map(y).reduce((a, b) => a > b ? a : b);
    final body = words.where((w) => y(w) > headerY + height * .7).toList()
      ..sort((a, b) => y(a).compareTo(y(b)));
    final rows = <List<OcrWord>>[];
    for (final word in body) {
      if (rows.isEmpty || (y(word) - y(rows.last.first)).abs() > height * .85) {
        rows.add([]);
      }
      rows.last.add(word);
    }
    final items = <DraftItem>[];
    for (final row in rows) {
      final raw = <String, String>{};
      final cells = <String, List<OcrWord>>{};
      for (final word in row) {
        var index =
            columns.indexWhere((c) => word.x < c.value.left - height * .35) - 1;
        if (index < 0) {
          index = word.x < columns.first.value.left - height * .35
              ? 0
              : columns.length - 1;
        }
        cells.putIfAbsent(columns[index].key, () => []).add(word);
      }
      for (final entry in cells.entries) {
        entry.value.sort((a, b) => a.left.compareTo(b.left));
        raw[entry.key] = entry.value.map((w) => w.text).join(' ').trim();
      }
      final name = raw['name'] ?? '';
      if (name.isEmpty ||
          RegExp(
            r'^(общо|сума|total|ддс|vat)\b',
            caseSensitive: false,
          ).hasMatch(name)) {
        continue;
      }
      final uncertain = <String>[
        for (final entry in cells.entries)
          if (entry.value.any((w) => w.confidence < 85)) entry.key,
      ];
      final qty = parseQuantity(raw['ordered'] ?? '') == null
          ? ''
          : raw['ordered']!;
      final expiry = parseDocumentDate(raw['expiry'] ?? '') == null
          ? ''
          : raw['expiry']!;
      final code = raw['barcode'] ?? '';
      final barcode = gtinKey(code) == null ? '' : code;
      if (qty.isEmpty) uncertain.add('ordered');
      if (expiry.isEmpty) uncertain.add('expiry');
      if (code.isNotEmpty && barcode.isEmpty) uncertain.add('barcode');
      items.add(
        DraftItem(
          name: name,
          supplierCode: raw['supplierCode'] ?? '',
          barcode: barcode,
          ordered: qty,
          received: qty,
          unit: raw['unit'] ?? '',
          expiry: expiry,
          lot: raw['lot'] ?? '',
          original: raw,
          uncertainFields: uncertain,
        ),
      );
    }
    return items.isEmpty
        ? original
        : TableParseResult(
            items,
            'Локален parser по заглавията на колоните. Автоматичните стойности изискват проверка; липсващите не се допълват.',
          );
  }
}
