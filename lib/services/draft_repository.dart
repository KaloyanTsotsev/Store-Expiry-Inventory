import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models/delivery_draft.dart';

class DraftRepository {
  final Future<Directory> Function() rootDirectory;
  Future<void> _pending = Future.value();
  DraftRepository({Future<Directory> Function()? rootDirectory})
    : rootDirectory = rootDirectory ?? getApplicationSupportDirectory;

  Future<Directory> _owner(String ownerId) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(ownerId)) {
      throw ArgumentError('Невалиден служител.');
    }
    final root = await rootDirectory();
    return Directory('${root.path}/delivery_drafts/$ownerId')
        .create(recursive: true);
  }

  Future<Directory> _folder(DeliveryDraft draft) async {
    if (!RegExp(r'^[a-zA-Z0-9]+$').hasMatch(draft.id)) {
      throw ArgumentError('Невалидна чернова.');
    }
    final owner = await _owner(draft.ownerId);
    return Directory('${owner.path}/${draft.id}').create(recursive: true);
  }

  /// A single repository serializes immutable snapshots; file rename commits atomically.
  Future<void> save(DeliveryDraft draft) {
    draft.updatedAt = DateTime.now();
    final snapshot = jsonEncode(draft.toJson());
    final operation = _pending.catchError((Object _) {}).then((_) async {
      final owner = await _owner(draft.ownerId);
      if (await File('${owner.path}/.deleted_${draft.id}').exists()) {
        throw StateError('Черновата е изтрита.');
      }
      final folder = await _folder(draft);
      final file = File('${folder.path}/draft.json');
      if (await file.exists()) {
        final previous = jsonDecode(await file.readAsString()) as Map;
        final incoming = jsonDecode(snapshot) as Map;
        if (previous['status'] == 'finalized' &&
            incoming['status'] != 'finalized') {
          throw StateError(
            'Доставката вече е приключена. Старо записване е отказано.',
          );
        }
        if (previous['stagingRequest'] != null &&
            jsonEncode(previous['stagingRequest']) !=
                jsonEncode(incoming['stagingRequest'])) {
          throw StateError(
            'Подготвената сървърна чернова е заключена до потвърждение.',
          );
        }
        if (previous['finalizationRequest'] != null &&
            jsonEncode(previous['finalizationRequest']) !=
                jsonEncode(incoming['finalizationRequest'])) {
          throw StateError(
            'Заявката за приключване е заключена до потвърждение от сървъра.',
          );
        }
      }
      final temporary = File('${folder.path}/draft.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      if (await file.exists()) {
        await file.copy('${folder.path}/draft.previous.json');
      }
      await temporary.rename(file.path);
    });
    _pending = operation;
    return operation;
  }

  Future<DeliveryDraft> load(String ownerId, String id) async {
    final owner = await _owner(ownerId);
    if (await File('${owner.path}/.deleted_$id').exists()) {
      throw StateError('Черновата е изтрита.');
    }
    final shell = DeliveryDraft(id: id, ownerId: ownerId);
    final folder = await _folder(shell);
    final file = File('${folder.path}/draft.json');
    final draft = DeliveryDraft.fromJson(
      Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map),
    );
    if (draft.ownerId != ownerId || draft.id != id) {
      throw const FormatException('Несъответстващ собственик на чернова.');
    }
    return draft;
  }

  Future<List<DeliveryDraft>> list(String ownerId) async {
    await _pending.catchError((Object _) {});
    final folder = await _owner(ownerId);
    final drafts = <DeliveryDraft>[];
    await for (final entry in folder.list()) {
      if (entry is Directory) {
        final id = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (await File('${folder.path}/.deleted_$id').exists()) continue;
        drafts.add(await load(ownerId, id));
      }
    }
    drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return drafts;
  }

  Future<DraftPage> importImage(
    DeliveryDraft draft,
    XFile image, {
    String? pageId,
  }) async {
    final folder = await _folder(draft);
    final id = newDraftId();
    final extension = image.path.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
    final path = '${folder.path}/$id.$extension';
    await image.saveTo(path);
    final hash = await sha256.bind(File(path).openRead()).first;
    return DraftPage(
      id: pageId ?? id,
      imagePath: path,
      imageHash: hash.toString(),
    );
  }

  Future<void> rememberPicker(
    DeliveryDraft draft, {
    String? replacingPage,
  }) async {
    await save(draft);
    final root = await rootDirectory();
    await File('${root.path}/pending_delivery_picker.json').writeAsString(
      jsonEncode({
        'ownerId': draft.ownerId,
        'id': draft.id,
        'replacingPage': replacingPage,
      }),
      flush: true,
    );
  }

  Future<void> clearPicker() async {
    final root = await rootDirectory();
    final file = File('${root.path}/pending_delivery_picker.json');
    if (await file.exists()) await file.delete();
  }

  Future<DeliveryDraft?> recoverPicker(
    String ownerId,
    ImagePicker picker,
  ) async {
    final root = await rootDirectory();
    final pending = File('${root.path}/pending_delivery_picker.json');
    if (!await pending.exists()) return null;
    final json = jsonDecode(await pending.readAsString()) as Map;
    // Do not consume another employee's recovered images.
    if (json['ownerId'] != ownerId) return null;
    final lost = await picker.retrieveLostData();
    if (lost.exception != null) throw lost.exception!;
    final draft = await load(ownerId, json['id'] as String);
    for (final image in lost.files ?? <XFile>[]) {
      final index = draft.pages.indexWhere(
        (p) => p.id == json['replacingPage'],
      );
      final page = await importImage(
        draft,
        image,
        pageId: index < 0 ? null : draft.pages[index].id,
      );
      if (index >= 0) {
        draft.pages[index] = page;
      } else {
        draft.pages.add(page);
      }
      await save(draft);
      if (index >= 0) await cleanupUnusedImages(draft);
    }
    await clearPicker();
    return draft;
  }

  Future<Directory> _verifiedFolder(DeliveryDraft draft) async {
    final owner = await _owner(draft.ownerId);
    final folder = await _folder(draft);
    final parent = await owner.resolveSymbolicLinks();
    final root = await (await rootDirectory()).resolveSymbolicLinks();
    final expectedOwner =
        '$root${Platform.pathSeparator}delivery_drafts${Platform.pathSeparator}${draft.ownerId}';
    if (parent != expectedOwner) {
      throw StateError('Небезопасна директория на служител.');
    }
    final target = await folder.resolveSymbolicLinks();
    final expected = '$parent${Platform.pathSeparator}${draft.id}';
    if (target != expected || await FileSystemEntity.isLink(folder.path)) {
      throw StateError('Небезопасна директория на чернова.');
    }
    return folder;
  }

  Future<void> cleanupUnusedImages(DeliveryDraft draft) async {
    final folder = await _verifiedFolder(draft);
    final active = draft.pages
        .map((p) => File(p.imagePath).absolute.uri.normalizePath().path)
        .toSet();
    // Do not leave deleted/retaken page OCR in the previous snapshot.
    await File('${folder.path}/draft.previous.json')
        .writeAsString(jsonEncode(draft.toJson()), flush: true);
    await for (final entity in folder.list(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (entity is File &&
          RegExp(r'^[a-z0-9]+\.(jpg|png)$').hasMatch(name) &&
          !active.contains(entity.absolute.uri.normalizePath().path)) {
        await entity.delete();
      }
    }
  }

  Future<void> removePage(DeliveryDraft draft, String pageId) async {
    final index = draft.pages.indexWhere((p) => p.id == pageId);
    if (index < 0) return;
    final page = draft.pages.removeAt(index);
    try {
      await save(draft);
    } catch (_) {
      draft.pages.insert(index, page);
      rethrow;
    }
    await cleanupUnusedImages(draft);
  }

  /// Local drafts only. Server delivery deletion requires the protected endpoint
  /// described in the V3 server contract and is never attempted here.
  Future<void> deleteDraft(DeliveryDraft draft, {required String employeeId}) {
    if (draft.ownerId != employeeId ||
        draft.status != 'draft' ||
        draft.finalizationRequest != null ||
        draft.stagingRequest != null) {
      return Future.error(
        StateError('Може да изтриете само собствена незавършена чернова.'),
      );
    }
    final operation = _pending.catchError((Object _) {}).then<void>((_) async {
      final stored = await load(employeeId, draft.id);
      if (stored.status != 'draft' ||
          stored.finalizationRequest != null ||
          stored.stagingRequest != null) {
        throw StateError('Финализирана доставка не се изтрива.');
      }
      final folder = await _verifiedFolder(stored);
      final owner = await _owner(employeeId);
      await File('${owner.path}/.deleted_${draft.id}')
          .writeAsString('deleted', flush: true);
      await folder.delete(recursive: true);
      final root = await rootDirectory();
      final picker = File('${root.path}/pending_delivery_picker.json');
      if (await picker.exists()) {
        final pending = jsonDecode(await picker.readAsString()) as Map;
        if (pending['ownerId'] == employeeId && pending['id'] == draft.id) {
          await picker.delete();
        }
      }
    });
    _pending = operation;
    return operation;
  }
}
