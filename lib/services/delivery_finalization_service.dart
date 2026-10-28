import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../models/delivery_draft.dart';
import 'pocketbase_service.dart';

import 'package:flutter/foundation.dart';

const backendV2Required =
    'Реалното приключване изисква одобрен и внедрен backend V2. '
    'Доставката остава чернова; продукти, партиди и движения не са записани.';

class DeliveryFinalization {
  static String differenceText(num received, num requested) {
    final difference = received - requested;
    if (difference == difference.roundToDouble()) {
      return difference.toStringAsFixed(2);
    }
    final text = difference.toStringAsPrecision(12);
    return text.contains('e') ? text : text.replaceFirst(RegExp(r'0+$'), '');
  }

  static List<String> errors(DeliveryDraft draft) => [
    if (draft.items.length > 500 || draft.pages.length > 50)
      'Една доставка може да съдържа до 500 позиции и 50 страници.',
    if (!draft.allReviewed)
      'Проверете всички позиции и сроковете на получените продукти.',
    if (draft.items.any((i) => parseQuantity(i.ordered) == null))
      'Коригирайте заявените количества преди приключване.',
  ];

  static List<Map<String, dynamic>> lines(DeliveryDraft draft) => [
    for (final page in draft.pages)
      for (final item in page.items)
        {
          'line_id': item.id,
          'source_row_id': item.sourceRowId,
          'page_id': page.id,
          'name': item.name.trim(),
          'supplier_code': item.supplierCode.trim(),
          'product_id': item.productId ?? '',
          'proposed_new': item.proposedNewProduct,
          'requested_quantity': parseQuantity(item.ordered),
          'received_quantity': parseQuantity(item.received),
          'expiry_date':
              parseDocumentDate(item.expiry)
                  ?.toIso8601String()
                  .substring(0, 10) ??
              '',
          'lot_number': normalizeLotNumber(item.lot),
          'checked': item.checked,
        },
  ];

  static Map<String, dynamic> request(DeliveryDraft draft) {
    if (errors(draft).isNotEmpty ||
        draft.status != 'draft' ||
        draft.serverId == null ||
        draft.serverRevision == null) {
      throw StateError(
        'Нужна е проверена, синхронизирана сървърна чернова с актуална версия.',
      );
    }
    return {
      'operation_key': 'finalize:${draft.serverId}',
      'expected_revision': draft.serverRevision,
      'lines': lines(draft),
    };
  }
}

abstract interface class DeliveryFinalizer {
  bool get available;
  Future<void> prepare(DeliveryDraft draft, Future<void> Function() persist);
  Future<Map<String, dynamic>> finalize(
    String serverId,
    Map<String, dynamic> request,
  );
}

class PocketBaseDeliveryFinalizer implements DeliveryFinalizer {
  bool _available = false;
  @override
  bool get available => _available;

  Future<void> probe() async {
    _available = false;
    final pb = PocketBaseService.pb;
    if (!pb.authStore.isValid ||
        pb.authStore.record?.collectionName != 'employees') {
      return;
    }
    try {
      final info = await pb.send<Map<String, dynamic>>(
        '/api/store/capabilities',
      );
      _available =
          info['protocol'] == 2 &&
          info['atomic_finalization'] == true &&
          info['staging'] == true &&
          info['photos'] == true;
    } catch (e, stackTrace) {
      _available = false;
      debugPrint('V2 capabilities probe failed: $e');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  Future<void> prepare(
    DeliveryDraft draft,
    Future<void> Function() persist,
  ) async {
    if (!available) throw StateError(backendV2Required);
    if (draft.finalizationRequest != null) {
      return; // A lost final response must replay finalize, not restage.
    }
    if (DeliveryFinalization.errors(draft).isNotEmpty) {
      throw StateError('Доставката не е готова за приключване.');
    }
    final pb = PocketBaseService.pb;
    if (draft.stagingRequest == null) {
      final pages = <Map<String, dynamic>>[];
      for (final page in draft.pages) {
        final hasPhoto = page.imagePath.isNotEmpty;
        final hash = hasPhoto
            ? (await sha256.bind(File(page.imagePath).openRead()).first)
                  .toString()
            : '';
        pages.add({
          'id': page.id,
          'recognized': page.recognized,
          'has_photo': hasPhoto,
          'image_hash': hash,
          'text': page.evidenceText,
          'words': page.words.map((w) => w.toJson()).toList(),
          'width': page.width,
          'height': page.height,
        });
      }
      final lines = DeliveryFinalization.lines(draft);
      for (var i = 0; i < lines.length; i++) {
        lines[i]['original_ocr'] = draft.items.elementAt(i).original;
      }
      final payload = <String, dynamic>{
        'client_id': draft.id,
        'expected_revision': draft.serverRevision ?? 0,
        'supplier': draft.supplier,
        'document_number': draft.documentNumber,
        'document_date':
            parseDocumentDate(draft.documentDate)
                ?.toIso8601String()
                .substring(0, 10) ??
            '',
        'pages': pages,
        'lines': lines,
      };
      final digest = sha256
          .convert(utf8.encode(jsonEncode(payload)))
          .toString();
      draft.stagingRequest = {
        'operation_key': 'stage:${draft.id}:$digest',
        ...payload,
      };
      await persist();
    }
    final staged = await pb.send<Map<String, dynamic>>(
      '/api/store/drafts/stage',
      method: 'POST',
      body: draft.stagingRequest!,
    );
    if (staged['delivery_id'] is! String ||
        staged['revision'] is! int ||
        staged['status'] != 'draft') {
      throw const FormatException(
        'Невалидно потвърждение за сървърната чернова.',
      );
    }
    draft.serverId = staged['delivery_id'] as String;
    draft.serverRevision = staged['revision'] as int;
    await persist();
    final path =
        '/api/store/deliveries/${Uri.encodeComponent(draft.serverId!)}';
    final status = await pb.send<Map<String, dynamic>>('$path/status');
    if (status['status'] != 'draft' ||
        status['revision'] is! int ||
        status['pages'] is! List) {
      throw StateError(
        'Доставката е променена или вече е приключена на друг телефон.',
      );
    }
    draft.serverRevision = status['revision'] as int;
    await persist();
    final remotePages = status['pages'] as List;
    for (final raw in draft.stagingRequest!['pages'] as List) {
      if (raw['has_photo'] != true) continue;
      final remote = remotePages.where((p) => p['id'] == raw['id']).firstOrNull;
      if (remote == null || remote['image_hash'] != raw['image_hash']) {
        throw StateError(
          'Сървърната страница е променена. Черновата е запазена.',
        );
      }
      if (remote['uploaded_hash'] == raw['image_hash']) continue;
      final page = draft.pages.firstWhere((p) => p.id == raw['id']);
      final actual = (await sha256.bind(File(page.imagePath).openRead()).first)
          .toString();
      if (actual != raw['image_hash']) {
        throw StateError('Снимката е променена след потвърждението.');
      }
      final uploaded = await pb.send<Map<String, dynamic>>(
        '$path/pages/${Uri.encodeComponent(page.id)}/photo',
        method: 'POST',
        body: {
          'expected_revision': draft.serverRevision.toString(),
          'image_hash': actual,
        },
        files: [await http.MultipartFile.fromPath('photo', page.imagePath)],
      );
      if (uploaded['delivery_id'] != draft.serverId ||
          uploaded['uploaded_hash'] != actual ||
          uploaded['revision'] is! int) {
        throw const FormatException('Снимката не е потвърдена от сървъра.');
      }
      draft.serverRevision = uploaded['revision'] as int;
      await persist();
    }
  }

  @override
  Future<Map<String, dynamic>> finalize(
    String serverId,
    Map<String, dynamic> request,
  ) async {
    if (!available) throw StateError(backendV2Required);
    final pb = PocketBaseService.pb;
    if (!pb.authStore.isValid ||
        pb.authStore.record?.collectionName != 'employees') {
      throw StateError('Влезте отново със служебния профил.');
    }
    final response = await pb.send<Map<String, dynamic>>(
      request['catalog_confirmed'] == true
          ? '/api/store/catalog/deliveries/${Uri.encodeComponent(serverId)}/finalize'
          : '/api/store/deliveries/${Uri.encodeComponent(serverId)}/finalize',
      method: 'POST',
      body: request,
    );
    final revision = response['revision'];
    if (response['status'] != 'finalized' ||
        response['delivery_id'] != serverId ||
        revision is! int ||
        revision <= (request['expected_revision'] as int)) {
      throw const FormatException(
        'Сървърът не потвърди приключването. Черновата е запазена.',
      );
    }
    return response;
  }
}

String finalizationError(Object error) {
  if (error is ClientException) {
    if (error.statusCode == 404 ||
        error.statusCode == 501 ||
        error.statusCode == 503) {
      return 'Endpoint-ът за приключване не е достъпен или backend V2 не е включен. '
          'Запазената заявка остава за проверка; не създавайте повторна доставка.';
    }
    if (error.statusCode == 409) {
      return 'Има конфликт с версията или доставката вече е обработена на друг телефон. '
          'Не създавайте нова доставка. Запазената заявка остава за проверка и повторение със същия ключ.';
    }
    if (error.statusCode == 0) {
      return 'Няма потвърден отговор от сървъра. Възможно е заявката да е обработена. '
          'Черновата и проверките са запазени; повторението използва същия ключ.';
    }
  }
  return 'Доставката не е потвърдена: ${PocketBaseService.errorMessage(error)}';
}
