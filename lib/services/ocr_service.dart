import '../models/delivery_draft.dart';

abstract class OcrEngine {
  Future<Map<String, dynamic>> recognize(String imagePath);
}

String normalizedProductName(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

class TableParseResult {
  final List<DraftItem> items;
  final String note;
  TableParseResult(this.items, this.note);
}

bool documentMayBeDuplicate(DraftPage first, DraftPage second) {
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
          tokensA.intersection(tokensB).length / tokensA.union(tokensB).length >
              .55);
}
