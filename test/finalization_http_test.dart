import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/delivery_finalization_service.dart';
import 'package:expiry_tracker/services/pocketbase_service.dart';

DeliveryDraft reviewedDraft() => DeliveryDraft(
  ownerId: 'employee1',
  serverId: 'serverdelivery1',
  serverRevision: 3,
  pages: [
    DraftPage(
      imagePath: '',
      recognized: true,
      items: [
        DraftItem(
          name: 'Мляко',
          ordered: '12',
          received: '6',
          expiry: '08.11.2026',
          proposedNewProduct: true,
          checked: true,
        ),
      ],
    ),
  ],
);

class _EnabledPocketBaseClient extends PocketBaseDeliveryFinalizer {
  @override
  bool get available => true;
}

void main() {
  test('Enabled adapter posts exactly once to custom endpoint with employee authorization', () async {
    final pb = PocketBaseService.pb;
    final original = pb.baseURL;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    try {
      pb.baseURL = 'http://127.0.0.1:${server.port}';
      final payload = base64Url
          .encode(utf8.encode(jsonEncode({'exp': 4102444800})))
          .replaceAll('=', '');
      final token = 'header.$payload.signature';
      pb.authStore.save(
        token,
        RecordModel.fromJson({
          'id': 'employee1',
          'collectionName': 'employees',
        }),
      );
      final packet = DeliveryFinalization.request(reviewedDraft());
      server.listen((request) async {
        requests++;
        expect(request.method, 'POST');
        expect(
          request.uri.path,
          '/api/store/deliveries/serverdelivery1/finalize',
        );
        expect(request.headers.value('authorization'), token);
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body, packet);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'delivery_id': 'serverdelivery1',
            'status': 'finalized',
            'revision': 4,
            'lines': [],
          }),
        );
        await request.response.close();
      });
      final response = await _EnabledPocketBaseClient().finalize(
        'serverdelivery1',
        packet,
      );
      expect(response['status'], 'finalized');
      expect(requests, 1);
    } finally {
      await server.close(force: true);
      pb.baseURL = original;
      pb.authStore.clear();
    }
  });
}
