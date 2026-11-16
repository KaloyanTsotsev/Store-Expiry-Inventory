import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import '../models/expiry_batch.dart';
import 'package:shared_preferences/shared_preferences.dart';
class PocketBaseService {
  static const String defaultServerUrl = String.fromEnvironment(
    'POCKETBASE_URL',
    defaultValue: 'http://192.168.100.46:8090',
  );

  static PocketBase pb = PocketBase(defaultServerUrl);

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();

    final savedUrl = prefs.getString('pocketbase_server_url');

    final url = savedUrl ?? defaultServerUrl;

    pb = PocketBase(url);
  }

  static Future<void> saveServerIp(String ipAddress) async {
    final ip = ipAddress.trim();

    final parts = ip.split('.');

    if (parts.length != 4 ||
        parts.any((part) {
          final number = int.tryParse(part);
          return part.isEmpty ||
              number == null ||
              number < 0 ||
              number > 255 ||
              number.toString() != part;
        })) {
      throw const FormatException('Въведете валиден IPv4 адрес.');
    }

    final newUrl = 'http://$ip:8090';

    // Проверяваме новия сървър, преди да запазим адреса.
    final testClient = PocketBase(newUrl);

    final response = await testClient
        .send<Map<String, dynamic>>('/api/health')
        .timeout(const Duration(seconds: 8));

    if (response['code'] != 200) {
      throw StateError('Сървърът не потвърди успешна връзка.');
    }

    // Запазваме адреса само след успешна проверка.
    final prefs = await SharedPreferences.getInstance();

    final saved = await prefs.setString(
      'pocketbase_server_url',
      newUrl,
    );

    if (!saved) {
      throw StateError('IP адресът не можа да бъде запазен.');
    }

    // При смяна на сървъра изчистваме старата сесия.
    if (pb.baseURL != newUrl) {
      pb.authStore.clear();
      pb = PocketBase(newUrl);
    }
  }

  static Future<void> login(String username, String password) async {
    await pb.collection('employees').authWithPassword(username, password);
  }

  static void logout() => pb.authStore.clear();

  static void _requireEmployee() {
    if (!pb.authStore.isValid ||
        pb.authStore.record?.collectionName != 'employees') {
      throw StateError('Сесията е невалидна или е изтекла. Влезте отново.');
    }
  }

  static Future<List<RecordModel>> getProducts() async {
    _requireEmployee();
    final records = await pb.collection('products').getFullList(sort: 'name');
    if (kDebugMode) {
      debugPrint(
        'products.getFullList: ${records.length} records; '
        '${_authContext()}',
      );
    }
    return records;
  }

  static Future<RecordModel?> findProductByBarcode(String barcode) async {
    _requireEmployee();
    final code = barcode.trim();
    if (code.isEmpty) throw ArgumentError('Въведете баркод.');
    final matches = await pb
        .collection('products')
        .getList(
          perPage: 2,
          filter: pb.filter('barcode = {:barcode}', {'barcode': code}),
        );
    if (matches.items.length > 1) {
      throw StateError('Баркодът е свързан с повече от един продукт.');
    }
    return matches.items.firstOrNull;
  }

  static Future<void> discardDeliveryDraft(
    String owner,
    String clientId,
  ) async {
    _requireEmployee();
    if (pb.authStore.record?.id != owner) {
      throw StateError('Черновата е на друг служител.');
    }
    final receipt = await pb
        .send<Map<String, dynamic>>(
          '/api/store/drafts/discard',
          method: 'POST',
          body: {'client_id': clientId},
        )
        .timeout(const Duration(seconds: 15));
    if (receipt['status'] != 'discarded' || receipt['client_id'] != clientId) {
      throw const FormatException(
        'Сървърът не потвърди изтриването на черновата.',
      );
    }
  }

  static Future<void> sendExpiryHandling(
    String owner,
    Map<String, dynamic> command,
  ) async {
    _requireEmployee();
    if (pb.authStore.record?.id != owner ||
        command['employee'] != owner ||
        command['kind'] != 'delete_batch') {
      throw StateError('Заявката не е за текущия служител.');
    }
    final id = command['batch'] as String;
    final capabilities = await pb
        .send<Map<String, dynamic>>('/api/store/capabilities')
        .timeout(const Duration(seconds: 10));
    if (capabilities['batch_deletion'] != true) {
      throw StateError(
        'Сървърът все още приключва партидите вместо да ги изтрива. Необходим е пакетът за окончателно изтриване; заявката не е изпратена.',
      );
    }
    final receipt = await pb
        .send<Map<String, dynamic>>(
          '/api/store/batches/${Uri.encodeComponent(id)}/handle',
          method: 'POST',
          body: {
            'action': 'delete_batch',
            'expected_revision': command['expected_revision'],
            'expiry_date': command['expiry_date'],
          },
        )
        .timeout(const Duration(seconds: 15));
    if (receipt['batch_id'] != id ||
        receipt['status'] != 'deleted' ||
        receipt['deleted'] != true) {
      throw const FormatException(
        'PocketBase не потвърди окончателното изтриване.',
      );
    }
  }

  static Future<List<ExpiryBatch>> getExpiryBatches({
    DateTime? now,
    bool includeClosed = false,
  }) async {
    _requireEmployee();
    final records = await pb
        .collection('batches')
        .getFullList(expand: 'product')
        .timeout(const Duration(seconds: 15));
    final date = now ?? DateTime.now();
    final batches = records
        .map((r) => ExpiryBatch.fromRecord(r, now: date))
        .where((b) => includeClosed || !b.closed)
        .toList();
    batches.sort((a, b) {
      final comparison = (a.days ?? 0x7fffffff).compareTo(b.days ?? 0x7fffffff);
      return comparison != 0 ? comparison : a.id.compareTo(b.id);
    });
    return batches;
  }

  static Future<RecordModel> createProduct({
    required String name,
    required String barcode,
    required String category,
  }) async {
    _requireEmployee();
    return pb
        .collection('products')
        .create(
          body: {
            'name': name.trim(),
            'barcode': barcode.trim(),
            'category': category.trim(),
          },
        );
  }

  static String _authContext() =>
      'collection=${pb.authStore.record?.collectionName}, '
      'employee=${pb.authStore.record?.id}, '
      'role=${jsonEncode(pb.authStore.record?.data['role'])}, '
      'valid=${pb.authStore.isValid}';

  /// Log server errors and auth metadata, never passwords or bearer tokens.
  static void logError(String operation, Object error) {
    if (!kDebugMode) return;
    debugPrint('$operation: ${_authContext()}');
    if (error is ClientException) {
      debugPrint(
        'HTTP ${error.statusCode}; path=${error.url?.path}; '
        'aborted=${error.isAbort}',
      );
      debugPrint(
        'Response: ${const JsonEncoder.withIndent('  ').convert(error.response)}',
      );
    } else {
      debugPrint('$operation: $error');
    }
  }

  static String errorMessage(Object error) {
    if (error is! ClientException) return error.toString();
    if (error.statusCode == 0) {
      return 'Няма връзка със сървъра (${pb.baseURL}). '
          'Проверете мрежата и дали PocketBase работи.\n'
          'HTTP: 0 (няма получен отговор).';
    }
    final details = const JsonEncoder.withIndent('  ').convert(error.response);
    final hint = switch (error.statusCode) {
      401 => 'Сесията е невалидна или е изтекла. Влезте отново.',
      403 => 'Сървърът отказва достъп до операцията.',
      400 =>
        'Проверете полетата и API Rules. Ако data е празно, '
            'отговорът не посочва конкретно поле; проверете и PocketBase Logs.',
      _ => 'Сървърът върна грешка.',
    };
    return 'HTTP ${error.statusCode}\n$hint\n$details';
  }
}
