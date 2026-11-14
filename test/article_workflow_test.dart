import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/paddle_document_adapter.dart';
import 'package:expiry_tracker/services/product_matcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

void main() {
  test('Bulgarian dates normalize and impossible dates are rejected', () {
    for (final input in [
      '25.11.2026',
      '25/11/2026',
      '25-11-2026',
      '25112026',
      '2026-11-25',
      '25.11.26',
    ]) {
      expect(formatDocumentDate(parseDocumentDate(input)!), '25.11.2026');
    }
    expect(parseDocumentDate('04/05/26'), DateTime(2026, 5, 4));
    expect(parseDocumentDate('29.02.24'), DateTime(2024, 2, 29));
    for (final input in [
      '31.02.2026',
      '29/02/26',
      '2026-13-25',
      '11/25/26',
      '1',
      '2026-02-31',
    ]) {
      expect(parseDocumentDate(input), isNull);
    }
  });
  test('OCR article stays a string; exact barcode wins without trusting the OCR name or page barcode', () {
    final result = PaddleDocumentAdapter().parse({
      'status': 'ok',
      'engine': 'PaddleOCR PP-OCRv5',
      'barcodes': ['999999'],
      'products': [
        {
          'article_code': '0000123',
          'name': 'Mлеко ...',
          'requested_quantity': 2,
          'expiry_date': '25/11/2026',
        },
      ],
    });
    final item = result.items.single
      ..articleBarcode = true
      ..catalogOnFinalize = true;
    expect(item.supplierCode, '0000123');
    expect(item.expiry, '25.11.2026');
    expect(item.uncertainFields, contains('name'));
    ProductMatcher.prepare(item, [], '');
    expect(item.proposedNewProduct, isTrue);
    expect(item.validationErrors, isEmpty);
    final canonical = RecordModel.fromJson({
      'id': 'milk',
      'name': 'Каталожно мляко',
      'barcode': '0000123',
      'active': true,
    });
    ProductMatcher.prepare(item, [canonical], '');
    expect(item.productId, 'milk');
    expect(item.name, 'Каталожно мляко');
    expect(item.checked, isFalse);
    expect(item.validationErrors, isEmpty);
    expect(item.original['name'], 'Mлеко ...');
  });
  test('Only an exact barcode is reused; supplier mappings do not affect recognition', () {
    final item = DraftItem(
      name: 'Сирене',
      supplierCode: '0002',
      requiresCatalogIdentity: true,
      articleBarcode: true,
    );
    final old = RecordModel.fromJson({
      'id': 'old',
      'name': 'Сирене',
      'barcode': '',
      'active': true,
      'supplier_identifiers': [
        {'supplier': 'Supplier', 'code': '0002', 'verified': true},
      ],
    });
    ProductMatcher.prepare(item, [old], 'Supplier');
    expect(item.productId, isNull);
    expect(item.proposedNewProduct, isTrue);
    final exact = RecordModel.fromJson({
      'id': 'exact',
      'name': 'Сирене',
      'barcode': '0002',
      'active': true,
    });
    ProductMatcher.prepare(item, [old, exact], 'Supplier');
    expect(item.productId, 'exact');
    item.edit('supplierCode', '2');
    ProductMatcher.prepare(item, [old, exact], 'Supplier');
    expect(item.productId, isNull);
    expect(item.proposedNewProduct, isTrue);
  });
}
