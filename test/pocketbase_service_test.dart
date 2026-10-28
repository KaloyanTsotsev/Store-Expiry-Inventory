import 'dart:convert';
import 'dart:io';

import 'package:expiry_tracker/services/pocketbase_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

void main() {
  final pb = PocketBaseService.pb;
  late HttpServer server;
  late String originalUrl;
  late String token;

  setUp(() async {
    originalUrl = pb.baseURL;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    pb.baseURL = 'http://127.0.0.1:${server.port}';
    final payload = base64Url.encode(
      utf8.encode(jsonEncode({'exp': 4102444800})),
    );
    token = 'eyJhbGciOiJIUzI1NiJ9.${payload.replaceAll('=', '')}.test';
    pb.authStore.save(
      token,
      RecordModel.fromJson({
        'id': 'employee1',
        'collectionName': 'employees',
        'role': 'admin',
      }),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    pb.baseURL = originalUrl;
    PocketBaseService.logout();
  });

  test(
    'getFullList sends employee authorization and follows all pages',
    () async {
      var requests = 0;
      server.listen((request) async {
        requests++;
        expect(request.headers.value('authorization'), token);
        expect(request.uri.path, '/api/collections/products/records');
        expect(request.uri.queryParameters['sort'], 'name');
        final page = int.parse(request.uri.queryParameters['page']!);
        final count = page == 1 ? 500 : 1;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'page': page,
            'perPage': 500,
            'totalItems': -1,
            'totalPages': -1,
            'items': List.generate(
              count,
              (index) => {
                'id': 'product${page}_$index',
                'name': 'Product $index',
              },
            ),
          }),
        );
        await request.response.close();
      });
      final products = await PocketBaseService.getProducts();
      expect(products, hasLength(501));
      expect(requests, 2);
    },
  );

  test('Dashboard uses authenticated batches with expansion, sorts urgent and excludes closed', () async {
    server.listen((request) async {
      expect(request.headers.value('authorization'), token);
      expect(request.method, 'GET');
      expect(request.uri.path, '/api/collections/batches/records');
      expect(request.uri.queryParameters['expand'], 'product');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'page': 1,
          'perPage': 500,
          'totalItems': 4,
          'totalPages': 1,
          'items': [
            {
              'id': 'future',
              'expiry_date': '2026-11-01',
              'quantity': 999,
              'expand': {
                'product': {'id': 'p1', 'name': 'Мляко'},
              },
            },
            {'id': 'expired', 'expiry_date': '2026-10-21'},
            {'id': 'closed', 'expiry_date': '2026-10-20', 'status': 'closed'},
            {'id': 'unknown', 'expiry_date': ''},
          ],
        }),
      );
      await request.response.close();
    });
    final batches = await PocketBaseService.getExpiryBatches(
      now: DateTime(2026, 10, 22),
    );
    expect(batches.map((b) => b.id), ['expired', 'future', 'unknown']);
    expect(batches[1].productName, 'Мляко');
    expect(batches.first.days, -1);
  });

  test('create uses shared employee auth and only product fields', () async {
    server.listen((request) async {
      expect(request.method, 'POST');
      expect(request.headers.value('authorization'), token);
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      expect(body, {
        'name': 'Milk',
        'barcode': '00123',
        'category': '',
        'active': true,
      });
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'id': 'product1', ...body}));
      await request.response.close();
    });
    final result = await PocketBaseService.createProduct(
      name: ' Milk ',
      barcode: ' 00123 ',
      category: ' ',
    );
    expect(result.id, 'product1');
  });

  test(
    'server validation details survive SDK and UI error formatting',
    () async {
      server.listen((request) async {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'message': 'Failed to create record.',
            'data': {
              'barcode': {
                'code': 'validation_not_unique',
                'message': 'Already used.',
              },
            },
          }),
        );
        await request.response.close();
      });
      try {
        await PocketBaseService.createProduct(
          name: 'Milk',
          barcode: '001',
          category: '',
        );
        fail('Expected server validation error');
      } on ClientException catch (error) {
        final message = PocketBaseService.errorMessage(error);
        expect(message, contains('HTTP 400'));
        expect(message, contains('barcode'));
        expect(message, contains('validation_not_unique'));
        expect(message, contains('Already used.'));
      }
    },
  );

  test('expired session is rejected before a product request', () async {
    PocketBaseService.logout();
    await expectLater(PocketBaseService.getProducts(), throwsStateError);
    await expectLater(
      PocketBaseService.createProduct(name: 'Milk', barcode: '', category: ''),
      throwsStateError,
    );
  });
}
