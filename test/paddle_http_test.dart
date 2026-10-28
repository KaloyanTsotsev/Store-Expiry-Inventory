import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:expiry_tracker/services/ocr_pipeline.dart';
import 'package:expiry_tracker/services/pocketbase_service.dart';
import 'package:expiry_tracker/services/product_catalog_service.dart';

Map<String, dynamic> realResponse() => jsonDecode(
  File('test/fixtures/paddle/http-test-v2.json').readAsStringSync(),
) as Map<String, dynamic>;
void main() {
  group('Authenticated Flutter OCR transport', () {
    late HttpServer server;
    late Directory temp;
    late File image;
    late String oldUrl;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('paddle-client-test-');
      image = File('${temp.path}/photo.jpg');
      await image.writeAsBytes([255, 216, 255, 0]);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final pb = PocketBaseService.pb;
      oldUrl = pb.baseURL;
      pb.baseURL = 'http://127.0.0.1:${server.port}';
      final payload = base64Url
          .encode(utf8.encode(jsonEncode({'exp': 4102444800})))
          .replaceAll('=', '');
      pb.authStore.save(
        'header.$payload.signature',
        RecordModel.fromJson({'id': 'employee', 'collectionName': 'employees'}),
      );
    });
    tearDown(() async {
      PocketBaseService.pb.baseURL = oldUrl;
      PocketBaseService.logout();
      await server.close(force: true);
      await temp.delete(recursive: true);
    });
    test(
      'Catalog capability 404 is explicit and never grants create access',
      () async {
        server.listen((request) async {
          expect(request.uri.path, '/api/store/catalog/capabilities');
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"message":"File not found."}');
          await request.response.close();
        });
        final access = await ProductCatalogService().probe();
        expect(access.available, isFalse);
        expect(access.canCreate, isFalse);
        expect(access.statusCode, 404);
        expect(access.message, contains('не е внедрен'));
      },
    );
    test('Catalog create permission comes from server capability, not a presumed role', () async {
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"protocol":3,"catalog":true,"can_manage":false}',
        );
        await request.response.close();
      });
      final access = await ProductCatalogService().probe();
      expect(access.available, isTrue);
      expect(access.canCreate, isFalse);
    });
    test('Only protected PB endpoint receives session token and image, returns full real JSON', () async {
      server.listen((request) async {
        expect(request.uri.path, '/api/store/ocr/recognize');
        expect(
          request.headers.value('Authorization'),
          PocketBaseService.pb.authStore.token,
        );
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body.keys, ['image_base64']);
        expect(base64Decode(body['image_base64']), [255, 216, 255, 0]);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(realResponse()));
        await request.response.close();
      });
      expect(
        await const ServerOcrEngine().recognize(image.path),
        realResponse(),
      );
    });
    test('Expired session is refused locally before uploading', () async {
      PocketBaseService.logout();
      await expectLater(
        const ServerOcrEngine().recognize(image.path),
        throwsStateError,
      );
    });
    for (final status in [400, 401, 403, 413, 429, 503, 504]) {
      test(
        'HTTP $status becomes a readable failure without fallback',
        () async {
          server.listen((request) async {
            await request.drain<void>();
            request.response.statusCode = status;
            request.response.headers.contentType = ContentType.json;
            request.response.write('{}');
            await request.response.close();
          });
          await expectLater(
            const ServerOcrEngine().recognize(image.path),
            throwsStateError,
          );
        },
      );
    }
    test('Client timeout remains a failure for manual entry; oversized file never uploaded', () async {
      server.listen((request) async {
        await request.drain<void>();
      });
      await expectLater(
        const ServerOcrEngine(timeout: Duration(milliseconds: 50))
            .recognize(image.path),
        throwsStateError,
      );
      final handle = await image.open(mode: FileMode.write);
      await handle.truncate(9 * 1024 * 1024 + 1);
      await handle.close();
      await expectLater(
        const ServerOcrEngine().recognize(image.path),
        throwsFormatException,
      );
    });
  });
}
