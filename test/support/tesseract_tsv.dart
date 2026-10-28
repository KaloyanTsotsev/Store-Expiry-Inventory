import 'package:expiry_tracker/models/delivery_draft.dart';

/// Decodes only word records. Empty high-confidence layout boxes are not words.
class TesseractTsv {
  final List<OcrWord> words;
  final int width, height;
  const TesseractTsv(this.words, this.width, this.height);

  factory TesseractTsv.parse(String source) {
    final rows = source.split(RegExp(r'\r?\n'));
    final words = <OcrWord>[];
    final lines = <String, int>{};
    var width = 0, height = 0;
    for (final row in rows.skip(1)) {
      final cells = row.split('\t');
      if (cells.length < 12) continue;
      final level = int.tryParse(cells[0]);
      final left = int.tryParse(cells[6]), top = int.tryParse(cells[7]);
      final w = int.tryParse(cells[8]), h = int.tryParse(cells[9]);
      if (left == null || top == null || w == null || h == null) continue;
      if (level == 1) {
        width = w;
        height = h;
      }
      final text = cells.sublist(11).join('\t');
      final confidence = double.tryParse(cells[10]);
      if (level != 5 ||
          text.trim().isEmpty ||
          confidence == null ||
          !confidence.isFinite ||
          w <= 0 ||
          h <= 0) {
        continue;
      }
      final key = cells.sublist(1, 5).join('/');
      final line = lines.putIfAbsent(key, () => lines.length + 1);
      words.add(
        OcrWord(
          text,
          confidence,
          left.toDouble(),
          top.toDouble(),
          (left + w).toDouble(),
          (top + h).toDouble(),
          line: line,
        ),
      );
    }
    return TesseractTsv(words, width, height);
  }
}
