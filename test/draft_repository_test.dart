import 'dart:io';

import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

class _RecoveredPicker extends ImagePicker {
  final List<XFile> images;
  int calls = 0;
  _RecoveredPicker(this.images);
  @override
  Future<LostDataResponse> retrieveLostData() async {
    calls++;
    return LostDataResponse(files: images, type: RetrieveType.image);
  }
}

void main() {
  late Directory root;
  late DraftRepository repository;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('expiry-draft-test-');
    repository = DraftRepository(rootDirectory: () async => root);
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'Submitted request cannot be deleted or overwritten by a stale draft',
    () async {
      final draft = DeliveryDraft(ownerId: 'employee1');
      await repository.save(draft);
      final stale = DeliveryDraft.fromJson(draft.toJson());
      draft.finalizationRequest = {
        'operation_key': 'finalize:server1',
        'expected_revision': 1,
        'lines': [],
      };
      await repository.save(draft);
      await expectLater(
        repository.deleteDraft(draft, employeeId: 'employee1'),
        throwsStateError,
      );
      await expectLater(repository.save(stale), throwsStateError);
      expect(
        (await repository.load(draft.ownerId, draft.id)).finalizationRequest,
        draft.finalizationRequest,
      );
      draft.status = 'finalized';
      draft.finalizationReceipt = {'status': 'finalized'};
      await repository.save(draft);
      final old = DeliveryDraft.fromJson({
        ...draft.toJson(),
        'status': 'draft',
      });
      await expectLater(repository.save(old), throwsStateError);
      expect(
        (await repository.load(draft.ownerId, draft.id)).status,
        'finalized',
      );
    },
  );
  test('Deleting own local draft removes photos and OCR; late saves cannot resurrect it', () async {
    final draft = DeliveryDraft(ownerId: 'employee1');
    final input = File('${root.path}/source.jpg');
    await input.writeAsBytes([1, 2, 3]);
    final page = await repository.importImage(draft, XFile(input.path));
    page.text = 'OCR secret';
    draft.pages.add(page);
    await repository.save(draft);
    await expectLater(
      repository.deleteDraft(draft, employeeId: 'employee2'),
      throwsStateError,
    );
    expect(await File(page.imagePath).exists(), isTrue);
    await repository.deleteDraft(draft, employeeId: 'employee1');
    expect(await File(page.imagePath).exists(), isFalse);
    expect(await input.exists(), isTrue);
    expect(await repository.list('employee1'), isEmpty);
    await expectLater(repository.save(draft), throwsStateError);
    final finalized = DeliveryDraft(ownerId: 'employee1', status: 'finalized');
    await repository.save(finalized);
    await expectLater(
      repository.deleteDraft(finalized, employeeId: 'employee1'),
      throwsStateError,
    );
  });
  test('Page removal cleans only its owned photo and previous OCR snapshot', () async {
    final draft = DeliveryDraft(ownerId: 'employee1');
    final input = File('${root.path}/source.jpg');
    await input.writeAsBytes([1, 2, 3]);
    draft.pages.add(await repository.importImage(draft, XFile(input.path)));
    draft.pages.first.text = 'removedOCR';
    draft.pages.add(await repository.importImage(draft, XFile(input.path)));
    final removed = draft.pages.first;
    await repository.save(draft);
    await repository.removePage(draft, removed.id);
    expect(await File(removed.imagePath).exists(), isFalse);
    expect(await File(draft.pages.single.imagePath).exists(), isTrue);
    expect(await input.exists(), isTrue);
    final previous = File(
      '${root.path}/delivery_drafts/employee1/${draft.id}/draft.previous.json',
    );
    expect(await previous.readAsString(), isNot(contains('removedOCR')));
  });
  test('Lost picker response restores a draft for its owner only', () async {
    final draft = DeliveryDraft(ownerId: 'employee1');
    await repository.rememberPicker(draft);
    final file = File('${root.path}/recovered.jpg');
    await file.writeAsBytes([1, 2, 3]);
    final picker = _RecoveredPicker([XFile(file.path)]);
    expect(await repository.recoverPicker('employee2', picker), isNull);
    expect(picker.calls, 0);
    final recovered = await repository.recoverPicker('employee1', picker);
    expect(recovered!.pages, hasLength(1));
    expect(picker.calls, 1);
    expect(await repository.recoverPicker('employee1', picker), isNull);
    expect(picker.calls, 1);
  });

  test(
    'Recovered retake replaces one page and clears only its OCR review',
    () async {
      final draft = DeliveryDraft(
        ownerId: 'employee1',
        pages: [
          DraftPage(
            imagePath: 'old',
            recognized: true,
            items: [DraftItem(name: 'Стар ред', checked: true)],
          ),
          DraftPage(
            imagePath: 'keep',
            recognized: true,
            text: 'Запази втората страница',
          ),
        ],
      );
      await repository.rememberPicker(
        draft,
        replacingPage: draft.pages.first.id,
      );
      final file = File('${root.path}/retake.jpg');
      await file.writeAsBytes([3, 2, 1]);
      final recovered = await repository.recoverPicker(
        'employee1',
        _RecoveredPicker([XFile(file.path)]),
      );
      expect(recovered!.pages, hasLength(2));
      expect(recovered.pages.first.id, draft.pages.first.id);
      expect(recovered.pages.first.recognized, isFalse);
      expect(recovered.pages.first.items, isEmpty);
      expect(recovered.pages[1].text, 'Запази втората страница');
    },
  );

  test(
    'Multiple pages and corrections survive closing and reopening a draft',
    () async {
      final draft = DeliveryDraft(ownerId: 'employee1');
      await repository.save(draft);
      for (var i = 0; i < 2; i++) {
        final input = File('${root.path}/input$i.jpg');
        await input.writeAsBytes([1, 2, 3, i]);
        draft.pages.add(await repository.importImage(draft, XFile(input.path)));
      }
      draft.pages[0].items.add(
        DraftItem(
          name: 'Тестов продукт',
          received: '10',
          productId: 'product1',
          expiry: '08.11.2026',
          lot: 'A',
          unit: 'бройка',
          checked: true,
        ),
      );
      await repository.save(draft);
      final reopened = await DraftRepository(rootDirectory: () async => root)
          .load('employee1', draft.id);
      expect(reopened.pages, hasLength(2));
      expect(reopened.checkedCount, 1);
      expect(await File(reopened.pages[1].imagePath).readAsBytes(), [
        1,
        2,
        3,
        1,
      ]);
      expect(await repository.list('employee2'), isEmpty);
    },
  );
  test('Concurrent local saves serialize snapshots and keep a previous version', () async {
    final draft = DeliveryDraft(ownerId: 'employee1', supplier: 'A');
    final first = repository.save(draft);
    draft.supplier = 'B';
    final second = repository.save(draft);
    await Future.wait([first, second]);
    final result = await repository.load(draft.ownerId, draft.id);
    expect(result.supplier, 'B');
    expect(
      await File(
        '${root.path}/delivery_drafts/employee1/${draft.id}/draft.previous.json',
      ).exists(),
      isTrue,
    );
  });
  test(
    'Disk failure is reported and draft can be saved after recovery',
    () async {
      final blocking = File('${root.path}/blocked');
      await blocking.writeAsString('not a directory');
      final failing = DraftRepository(
        rootDirectory: () async => Directory(blocking.path),
      );
      final draft = DeliveryDraft(ownerId: 'employee1');
      await expectLater(
        failing.save(draft),
        throwsA(isA<FileSystemException>()),
      );
      await repository.save(draft);
      expect((await repository.load(draft.ownerId, draft.id)).id, draft.id);
    },
  );
}
