import 'dart:convert';
import 'dart:io';

import 'package:expiry_tracker/services/pocketbase_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

void main() {
  for (final mode in ['deleted', 'closed', 'wrong_id', 'old_backend']) {
    test('Permanent deletion HTTP contract: $mode', () async {
      final pb = PocketBaseService.pb;
      final original = pb.baseURL;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var posts = 0;
      try {
        pb.baseURL = 'http://127.0.0.1:${server.port}';
        final payload = base64Url
            .encode(utf8.encode(jsonEncode({'exp': 4102444800})))
            .replaceAll('=', '');
        final token = 'header.$payload.signature';
        pb.authStore.save(
          token,
          RecordModel.fromJson({
            'id': 'employee',
            'collectionName': 'employees',
          }),
        );
        server.listen((request) async {
          expect(request.headers.value('authorization'), token);
          request.response.headers.contentType = ContentType.json;
          if (request.method == 'GET') {
            expect(request.uri.path, '/api/store/capabilities');
            request.response.write(
              jsonEncode({'batch_deletion': mode != 'old_backend'}),
            );
          } else {
            posts++;
            expect(request.method, 'POST');
            expect(
              request.uri.path,
              '/api/store/batches/bat000000000001/handle',
            );
            final body = jsonDecode(await utf8.decoder.bind(request).join());
            expect(body, {
              'action': 'delete_batch',
              'expected_revision': 4,
              'expiry_date': '2026-12-13',
            });
            request.response.write(
              jsonEncode({
                'batch_id': mode == 'wrong_id'
                    ? 'bat000000000002'
                    : 'bat000000000001',
                'status': mode == 'closed' ? 'closed' : 'deleted',
                'deleted': mode != 'closed',
              }),
            );
          }
          await request.response.close();
        });
        final result = PocketBaseService.sendExpiryHandling('employee', {
          'employee': 'employee',
          'batch': 'bat000000000001',
          'kind': 'delete_batch',
          'expected_revision': 4,
          'expiry_date': '2026-12-13',
        });
        if (mode == 'deleted') {
          await result;
        } else if (mode == 'old_backend') {
          await expectLater(result, throwsStateError);
        } else {
          await expectLater(result, throwsFormatException);
        }
        expect(posts, mode == 'old_backend' ? 0 : 1);
        await expectLater(
          PocketBaseService.sendExpiryHandling('employee', {
            'employee': 'employee',
            'batch': 'bat000000000001',
            'kind': 'handled',
          }),
          throwsStateError,
        );
        expect(
          posts,
          mode == 'old_backend' ? 0 : 1,
        ); // old outbox intent never sent
      } finally {
        pb.authStore.clear();
        pb.baseURL = original;
        await server.close(force: true);
      }
    });
  }
}
