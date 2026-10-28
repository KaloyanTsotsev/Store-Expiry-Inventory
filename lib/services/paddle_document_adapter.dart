import 'dart:convert';

import '../models/delivery_draft.dart';
import 'ocr_service.dart';

/// Consumes the existing service's structured rows, never a second OCR pass.
class PaddleDocumentAdapter {
  /// Only explicit page-level observations are accepted. Never infer a barcode
  /// from raw text, article codes, or product rows; never infer its symbology.
  List<PageBarcode> pageBarcodes(Map<String, dynamic> response) {
    final result = <PageBarcode>[];
    final seen = <String>{};
    void add(dynamic entry) {
      final raw = entry is Map
          ? Map<String, dynamic>.from(entry)
          : <String, dynamic>{'value': entry};
      final value = raw['value'] ?? raw['text'] ?? raw['data'];
      if (value is! String || value.trim().isEmpty) return;
      final suppliedType = raw['type'] ?? raw['format'];
      final type = suppliedType is String && suppliedType.trim().isNotEmpty
          ? suppliedType
          : null;
      if (seen.add(jsonEncode([value, type]))) {
        result.add(PageBarcode(value: value, type: type, original: raw));
      }
    }

    for (final key in ['barcodes', 'document_barcodes']) {
      final values = response[key];
      if (values is List) {
        for (final entry in values) {
          add(entry);
        }
      }
    }
    if (response['barcode'] != null) add(response['barcode']);
    return result;
  }

  void applyPageEvidence(DraftPage page, Map<String, dynamic> response) {
    // Replace the previous reading on this page. Re-import never appends copies.
    page.barcodes = pageBarcodes(response);
    page.text = jsonEncode(response);
  }

  TableParseResult parse(Map<String, dynamic> response) {
    final rows = response['products'];
    if (response['status'] != 'ok' ||
        response['engine'] != 'PaddleOCR PP-OCRv5' ||
        rows is! List ||
        rows.length > 500) {
      throw const FormatException(
        'Невалиден отговор от PaddleOCR. Въведете ръчно или опитайте отново.',
      );
    }
    String text(dynamic value) => value is String ? value : '';
    final items = <DraftItem>[];
    for (final row in rows) {
      if (row is! Map) throw const FormatException('Невалидна OCR позиция.');
      final quantity = row['requested_quantity'];
      final ordered = quantity is num && quantity.isFinite && quantity >= 0
          ? quantity.toString()
          : '';
      final iso = text(row['expiry_date']);
      var expiry = '';
      if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(iso)) {
        final parts = iso.split('-');
        final candidate = '${parts[2]}.${parts[1]}.${parts[0]}';
        if (parseDocumentDate(candidate) != null) expiry = candidate;
      }
      final name = text(row['name']),
          code = text(row['article_code']),
          unit = text(row['unit_raw']);
      items.add(
        DraftItem(
          supplierCode: code,
          name: name,
          ordered: ordered,
          unit: unit,
          expiry: expiry,
          lot: text(row['batch_number']),
          received: ordered,
          requiresCatalogIdentity: true,
          difference: '',
          checked: false,
          proposedNewProduct: false,
          original: {
            'supplierCode': code,
            'name': name,
            'ordered': quantity?.toString() ?? '',
            'unit': unit,
            'expiry': iso,
            'lot': text(row['batch_number']),
            'difference': row['difference']?.toString() ?? '',
            'raw_expiry_batch': text(row['raw_expiry_batch']),
            'raw_fields': jsonEncode(row['raw_fields']),
            'paddle_product': jsonEncode(row),
          },
          uncertainFields: [
            if (name.isEmpty) 'name',
            if (code.isEmpty) 'supplierCode',
            if (ordered.isEmpty) 'ordered',
            if (expiry.isEmpty) 'expiry',
          ],
        ),
      );
    }
    return TableParseResult(
      items,
      'Получени е предложено от Заявени. Сравнете с преброеното и потвърдете всяка позиция.',
    );
  }
}
