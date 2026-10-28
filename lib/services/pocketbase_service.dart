import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import '../models/expiry_batch.dart';

class PocketBaseService {
  static final pb = PocketBase('http://192.168.1.200:8090');

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

  static Future<List<ExpiryBatch>> getExpiryBatches({DateTime? now}) async {
    _requireEmployee();
    final records = await pb
        .collection('batches')
        .getFullList(expand: 'product');
    final date = now ?? DateTime.now();
    final batches = records
        .map((r) => ExpiryBatch.fromRecord(r, now: date))
        .where((b) => !b.closed)
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
            'active': true,
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
