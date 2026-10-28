import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/delivery_draft.dart';
import '../models/expiry_batch.dart';

class BatchCheckRepository {
  final Future<Directory> Function() rootDirectory;
  Future<void> _pending = Future.value();
  BatchCheckRepository({Future<Directory> Function()? rootDirectory})
    : rootDirectory = rootDirectory ?? getApplicationSupportDirectory;
  Future<File> _file(String owner) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(owner)) {
      throw ArgumentError('Невалиден служител.');
    }
    final root = await rootDirectory();
    return File('${root.path}/pending_batch_checks_$owner.json');
  }

  Future<List<Map<String, dynamic>>> list(String owner) async {
    final file = await _file(owner);
    if (!await file.exists()) return [];
    return (jsonDecode(await file.readAsString()) as List)
        .map((j) => Map<String, dynamic>.from(j as Map))
        .toList();
  }

  Future<void> _write(String owner, List<Map<String, dynamic>> items) async {
    final file = await _file(owner);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(items), flush: true);
    await temporary.rename(file.path);
  }

  Future<void> prepare({
    required String owner,
    required ExpiryBatch batch,
    required String kind,
    required String quantity,
    String reason = '',
  }) {
    final count = parseQuantity(quantity);
    if (batch.closed ||
        !['none', 'count', 'waste'].contains(kind) ||
        count == null ||
        (kind == 'none' && count != 0) ||
        (kind != 'none' && count <= 0) ||
        (kind == 'waste' && reason.trim().isEmpty)) {
      return Future.error(
        ArgumentError(
          'Проверете количеството и причината. Приключена партида не може да се променя.',
        ),
      );
    }
    final operation = _pending.catchError((Object _) {}).then<void>((_) async {
      final items = await list(owner);
      if (items.any((j) => j['batch'] == batch.id)) {
        throw StateError('Вече има неизпратена проверка за тази партида.');
      }
      items.add({
        'operation_key': newDraftId(),
        'employee': owner,
        'batch': batch.id,
        'kind': kind,
        'quantity': count,
        'reason': reason.trim(),
        'expected_revision': batch.revision,
        'observed_at_local': DateTime.now().toUtc().toIso8601String(),
        'sync_status': 'not_sent',
      });
      await _write(owner, items);
    });
    _pending = operation;
    return operation;
  }

  Future<void> cancel(String owner, String operationKey) {
    final operation = _pending.catchError((Object _) {}).then<void>((_) async {
      final items = await list(owner);
      items.removeWhere(
        (i) => i['operation_key'] == operationKey && i['employee'] == owner,
      );
      await _write(owner, items);
    });
    _pending = operation;
    return operation;
  }
}
