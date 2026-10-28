import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/paddle_document_adapter.dart';
import 'package:expiry_tracker/services/product_matcher.dart';
import 'package:expiry_tracker/services/delivery_catalog_service.dart';
import 'package:expiry_tracker/services/product_catalog_service.dart';

RecordModel product(
  String id, {
  String supplier = 'А',
  String code = '900001702',
  bool verified = true,
  bool active = true,
}) => RecordModel.fromJson({
  'id': id,
  'name': 'Каталожно мляко',
  'active': active,
  'supplier_identifiers': [
    {'supplier': supplier, 'code': code, 'verified': verified},
  ],
  'quantity': 999,
  'expiry_date': '2000-01-01',
  'lot_number': 'OLD',
});
DraftItem line() => DraftItem(
  name: 'OCR мляк0',
  supplierCode: '900001702',
  ordered: '12',
  received: '12',
  expiry: '08.11.2026',
  lot: 'L1',
  requiresCatalogIdentity: true,
  original: const {'name': 'OCR мляк0'},
);

class Catalog extends ProductCatalogService {
  Catalog({this.manager = true, this.loseFirst = false});
  final bool manager;
  bool loseFirst;
  int writes = 0, calls = 0;
  final Map<String, Map<String, dynamic>> journal = {};
  @override
  bool get canManage => manager;
  @override
  Future<bool> available() async => true;
  @override
  Future<Map<String, dynamic>> submit(
    Map<String, dynamic> body, {
    required bool proposal,
  }) async {
    calls++;
    if (!manager) throw StateError('Forbidden');
    final key = body['operation_key'] as String;
    if (!journal.containsKey(key)) {
      writes++;
      journal[key] = {
        'status': 'saved',
        'product': {'id': 'cat000000000001', ...body['fields'] as Map},
      };
    }
    if (loseFirst) {
      loseFirst = false;
      throw StateError('Lost response after commit');
    }
    return journal[key]!;
  }
}

void main() {
  test('Catalog-only confirmation permits missing delivery dates but never checks the row', () async {
    final item = line()
      ..expiry = ''
      ..received = ''
      ..ordered = '';
    final catalog = Catalog();
    await DeliveryCatalogService(catalog: catalog).confirm(
      item: item,
      supplier: 'А',
      products: [],
      physicallyConfirmed: true,
      catalogOnly: true,
      persist: () async {},
    );
    expect(catalog.writes, 1);
    expect(item.productId, 'cat000000000001');
    expect(item.checked, isFalse);
    expect(item.received, isEmpty);
    expect(item.expiry, isEmpty);
    expect(item.validationErrors, isNotEmpty);
  });
  test('Same supplier/code selects identity only across three deliveries, no name guessing', () {
    final p = product('p');
    final rows = <DraftItem>[];
    for (final (qty, date, lot) in [
      ('12', '08.11.2026', 'L1'),
      ('8', '15.11.2026', 'L2'),
      ('6', '22.11.2026', 'L3'),
    ]) {
      final item = line()
        ..ordered = qty
        ..received = qty
        ..expiry = date
        ..lot = lot;
      ProductMatcher.prepare(item, [p], 'А');
      expect(item.productId, 'p');
      expect(item.name, 'Каталожно мляко');
      expect(item.received, qty);
      expect(item.ordered, qty);
      expect(item.expiry, date);
      expect(item.lot, lot);
      expect(item.original['name'], 'OCR мляк0');
      expect(item.checked, isFalse);
      rows.add(item);
    }
    expect(rows.map((r) => r.id).toSet(), hasLength(3));
    final other = line()..name = 'Каталожно мляко';
    ProductMatcher.prepare(other, [p], 'Б');
    expect(other.productId, isNull);
    expect(other.proposedNewProduct, isTrue);
    expect(p.data['quantity'], 999);
    expect(p.data['lot_number'], 'OLD');
  });
  test('Ambiguous, unverified, inactive or malformed code blocks only affected row', () {
    for (final records in [
      [product('a'), product('b')],
      [product('a', verified: false)],
      [product('a', active: false)],
    ]) {
      final item = line();
      ProductMatcher.prepare(item, records, 'А');
      expect(item.productId, isNull);
      expect(item.proposedNewProduct, isFalse);
      expect(item.validationErrors, isNotEmpty);
    }
    final item = line()..supplierCode = '9?00';
    ProductMatcher.prepare(item, [], 'А');
    expect(item.proposedNewProduct, isFalse);
    final good = line();
    ProductMatcher.prepare(good, [product('a')], 'А');
    expect(good.productId, 'a');
  });
  test('Repeated OCR and same code with two dates/lots keeps independent rows, resets confirmations', () {
    final response = jsonDecode(
      File('test/fixtures/paddle/http-test-v2.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final a = PaddleDocumentAdapter().parse(response).items;
    a[1].edit('received', '10');
    a[1].checked = true;
    final b = PaddleDocumentAdapter().parse(response).items;
    expect(b, hasLength(37));
    expect(b[1].received, '12');
    expect(b[1].checked, isFalse);
    expect(a[1].received, '10');
    expect(a[1].id, isNot(b[1].id));
    final split = {
      ...response,
      'products': [
        response['products'][1],
        {
          ...response['products'][1] as Map,
          'expiry_date': '2026-11-15',
          'batch_number': 'L2',
          'requested_quantity': 6,
        },
      ],
    };
    final rows = PaddleDocumentAdapter().parse(split).items;
    for (final item in rows) {
      ProductMatcher.prepare(item, [product('p')], 'А');
    }
    expect(rows, hasLength(2));
    expect(rows.map((r) => r.productId).toSet(), {'p'});
    expect(rows.map((r) => r.expiry), ['08.11.2026', '15.11.2026']);
    expect(rows.map((r) => r.received), ['12', '6']);
  });
  test('Explicit manager confirmation creates product+mapping only, then next import reuses ID', () async {
    final catalog = Catalog();
    final service = DeliveryCatalogService(catalog: catalog);
    final item = line();
    ProductMatcher.prepare(item, [], 'А');
    expect(item.proposedNewProduct, isTrue);
    expect(catalog.writes, 0);
    await expectLater(
      service.confirm(
        item: item,
        supplier: 'А',
        products: [],
        physicallyConfirmed: false,
        persist: () async {},
      ),
      throwsStateError,
    );
    expect(catalog.calls, 0);
    final snapshots = <Map<String, dynamic>>[];
    final p = await service.confirm(
      item: item,
      supplier: 'А',
      products: [],
      physicallyConfirmed: true,
      persist: () async {
        snapshots.add(jsonDecode(jsonEncode(item.toJson())));
      },
    );
    expect(catalog.writes, 1);
    expect(snapshots.first['catalogRequest'], isNotNull);
    expect(item.productId, p.id);
    expect(item.proposedNewProduct, isFalse);
    expect(item.checked, isFalse);
    final next = line()
      ..received = '8'
      ..expiry = '15.11.2026';
    ProductMatcher.prepare(next, [p], 'А');
    expect(next.productId, p.id);
    expect(next.received, '8');
    expect(catalog.writes, 1);
  });
  test('Employee keeps new row pending manager; known identity needs no catalog write', () async {
    final catalog = Catalog(manager: false), item = line();
    final service = DeliveryCatalogService(catalog: catalog);
    await expectLater(
      service.confirm(
        item: item,
        supplier: 'А',
        products: [],
        physicallyConfirmed: true,
        persist: () async {},
      ),
      throwsStateError,
    );
    expect(catalog.calls, 0);
    expect(item.catalogRequest, isNull);
    expect(item.checked, isFalse);
    await service.confirm(
      item: item,
      supplier: 'А',
      products: [product('p')],
      physicallyConfirmed: true,
      persist: () async {},
    );
    expect(item.productId, 'p');
    expect(catalog.calls, 0);
  });
  test('Lost response reopens durable exact request and replays without duplicate product', () async {
    final catalog = Catalog(loseFirst: true),
        service = DeliveryCatalogService(catalog: catalog);
    final item = line();
    late Map<String, dynamic> saved;
    await expectLater(
      service.confirm(
        item: item,
        supplier: 'А',
        products: [],
        physicallyConfirmed: true,
        persist: () async {
          saved = jsonDecode(jsonEncode(item.toJson()));
        },
      ),
      throwsStateError,
    );
    final restored = DraftItem.fromJson(saved);
    final key = restored.catalogRequest!['operation_key'];
    await service.confirm(
      item: restored,
      supplier: 'А',
      products: [],
      physicallyConfirmed: true,
      persist: () async {},
    );
    expect(catalog.writes, 1);
    expect(catalog.calls, 2);
    expect(catalog.journal.keys, [key]);
    expect(restored.productId, 'cat000000000001');
    expect(restored.catalogRequest, isNull);
  });
  test('Disk failure blocks POST; retry persists first, unresolved payload cannot change', () async {
    final catalog = Catalog(), item = line();
    final service = DeliveryCatalogService(catalog: catalog);
    await expectLater(
      service.confirm(
        item: item,
        supplier: 'А',
        products: [],
        physicallyConfirmed: true,
        persist: () async {
          throw StateError('Disk full');
        },
      ),
      throwsStateError,
    );
    expect(catalog.calls, 0);
    item.name = 'Changed';
    await expectLater(
      service.confirm(
        item: item,
        supplier: 'А',
        products: [],
        physicallyConfirmed: true,
        persist: () async {},
      ),
      throwsStateError,
    );
    expect(catalog.calls, 0);
    item.name = 'OCR мляк0';
    await service.confirm(
      item: item,
      supplier: 'А',
      products: [],
      physicallyConfirmed: true,
      persist: () async {},
    );
    expect(catalog.writes, 1);
  });
}
