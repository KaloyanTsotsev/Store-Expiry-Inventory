import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/delivery_draft.dart';
import '../services/draft_repository.dart';
import '../services/ocr_service.dart';
import '../services/paddle_document_adapter.dart';
import '../services/ocr_pipeline.dart';
import '../services/pocketbase_service.dart';
import '../services/page_capture_service.dart';
import '../widgets/document_photo.dart';
import '../widgets/bulk_review_row.dart';
import '../services/product_matcher.dart';
import '../services/delivery_finalization_service.dart';
import 'delivery_item_screen.dart';

class DeliveryEditorScreen extends StatefulWidget {
  final DeliveryDraft draft;
  final DraftRepository repository;
  final bool startCamera;
  final OcrEngine? engine;
  final PageCapture? capture;
  final DeliveryFinalizer? finalizer;
  final Future<List<RecordModel>> Function()? catalogLoader;
  const DeliveryEditorScreen({
    super.key,
    required this.draft,
    required this.repository,
    this.startCamera = false,
    this.engine,
    this.capture,
    this.finalizer,
    this.catalogLoader,
  });
  @override
  State<DeliveryEditorScreen> createState() => _DeliveryEditorScreenState();
}

class _DeliveryEditorScreenState extends State<DeliveryEditorScreen> {
  late final capture = widget.capture ?? PageCaptureService();
  final parser = PaddleDocumentAdapter();
  bool busy = false;
  bool confirmingSave = false;
  bool dirty = false;
  String filter = 'all';
  final rowsAnchor = GlobalKey();
  final scroll = ScrollController();
  Timer? autosave;
  late final supplierInput = TextEditingController(text: draft.supplier);
  late final documentNumberInput = TextEditingController(
    text: draft.documentNumber,
  );
  late final documentDateInput = TextEditingController(
    text: draft.documentDate,
  );
  int revision = 0;
  String? error;
  String status = 'Черновата е записана на телефона';
  List<RecordModel> products = [];
  String? catalogError;
  DeliveryDraft get draft => widget.draft;
  late final finalizer = widget.finalizer ?? PocketBaseDeliveryFinalizer();
  bool get editingLocked =>
      busy ||
      draft.stagingRequest != null ||
      draft.finalizationRequest != null ||
      draft.status != 'draft';

  @override
  void initState() {
    super.initState();
    _loadCatalog();
    _probeBackend();
    if (widget.startCamera) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pick(camera: true));
    }
  }

  Future<void> _probeBackend() async {
    if (widget.finalizer != null) return;
    final client = finalizer as PocketBaseDeliveryFinalizer;
    await client.probe();
    if (mounted) setState(() {});
  }

  void _prepareIdentity(DraftItem item) {
    if (!item.articleBarcode) item.checked = false;
    item.articleBarcode = true;
    ProductMatcher.prepare(item, products, draft.supplier);
  }

  Future<void> _loadCatalog() async {
    if (draft.stagingRequest != null ||
        draft.finalizationRequest != null ||
        draft.status != 'draft') {
      return;
    }
    try {
      final records =
          await (widget.catalogLoader?.call() ??
              PocketBaseService.getProducts());
      if (mounted &&
          draft.stagingRequest == null &&
          draft.finalizationRequest == null &&
          draft.status == 'draft') {
        setState(() {
          products = records;
          catalogError = null;
          for (final item in draft.items) {
            _prepareIdentity(item);
          }
        });
        await _save();
      }
    } catch (e) {
      PocketBaseService.logError('delivery.catalog', e);
      if (mounted) {
        setState(() {
          catalogError = PocketBaseService.errorMessage(e);
          for (final item in draft.items) {
            if (!item.articleBarcode) _prepareIdentity(item);
          }
        });
      }
    }
  }

  Future<bool> _save() async {
    autosave?.cancel();
    final savedRevision = revision;
    try {
      await widget.repository.save(draft);
      if (mounted && savedRevision == revision) {
        setState(() {
          dirty = false;
          status = 'Черновата е записана на телефона';
        });
      }
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          error = 'Промените не са записани: $e';
          dirty = true;
          status = 'Има незаписани промени';
        });
      }
      return false;
    }
  }

  Future<void> _pick({required bool camera, DraftPage? replacing}) async {
    if (editingLocked) return;
    var imported = false;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (replacing != null && replacing.items.isNotEmpty) {
        final approved = await _confirm(
          'Повторна снимка',
          'Това ще замени снимката и проверките само за тази страница.',
        );
        if (!approved) return;
      }
      await widget.repository.rememberPicker(
        draft,
        replacingPage: replacing?.id,
      );
      final images = camera
          ? await capture.camera()
          : await capture.gallery(multiple: replacing == null);
      for (final image in images) {
        final page = await widget.repository.importImage(
          draft,
          image,
          pageId: replacing?.id,
        );
        final index = replacing == null ? -1 : draft.pages.indexOf(replacing);
        if (index >= 0) {
          draft.pages[index] = page;
        } else {
          draft.pages.add(page);
        }
        if (!await _save()) return;
        if (index >= 0) await widget.repository.cleanupUnusedImages(draft);
        imported = true;
      }
      await widget.repository.clearPicker();
    } catch (e) {
      if (mounted) setState(() => error = 'Снимката не е добавена: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (imported && mounted) await _recognize();
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отказ'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Потвърди'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _recognize({DraftPage? only}) async {
    if (editingLocked) return;
    if (only != null &&
        only.items.isNotEmpty &&
        !await _confirm(
          'Повторно разпознаване',
          'Ръчно направените корекции на тази страница ще се заменят.',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final pages = only == null
          ? draft.pages
                .where(
                  (p) =>
                      p.imagePath.isNotEmpty &&
                      (!p.recognized || p.error != null),
                )
                .toList()
          : [only];
      for (final page in pages) {
        if (mounted) {
          setState(
            () => status =
                'Разпознаване на страница ${draft.pages.indexOf(page) + 1}…',
          );
        }
        try {
          final data = await (widget.engine ?? const ServerOcrEngine())
              .recognize(page.imagePath);
          final parsed = parser.parse(data);
          page.words = [];
          parser.applyPageEvidence(page, data);
          page.refinements = [];
          page.width = 0;
          page.height = 0;
          page.elapsedMs = ((data['processing_seconds'] as num? ?? 0) * 1000)
              .round();
          page.items = parsed.items;
          for (final item in page.items) {
            _prepareIdentity(item);
          }
          page.layoutNote = parsed.note;
          page.recognized = true;
          page.error = null;
        } catch (e) {
          page.error = e.toString();
        }
        if (!await _save()) return;
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _editItem(DraftPage page, DraftItem item) async {
    if (editingLocked) return;
    final action = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => DeliveryItemScreen(
          item: item,
          imagePath: page.imagePath,
          products: products,
          supplier: draft.supplier,
          onReloadCatalog: () async {
            await _loadCatalog();
            return products;
          },
          onSave: () async {
            if (!await _save()) {
              throw StateError('Черновата не е записана. Опитайте отново.');
            }
          },
        ),
      ),
    );
    if (action == 'split') {
      item.checked = false;
      item.received = '';
      page.items.add(
        DraftItem(
          sourceRowId: item.sourceRowId,
          name: item.name,
          supplierCode: item.supplierCode,
          barcode: item.barcode,
          unit: item.unit,
          productSelectionConfirmed: item.productSelectionConfirmed,
          requiresCatalogIdentity: item.requiresCatalogIdentity,
          catalogOnFinalize: item.catalogOnFinalize,
          articleBarcode: item.articleBarcode,
          ordered: item.ordered,
          proposedNewProduct: item.proposedNewProduct,
          productId: item.productId,
          original: item.original,
        ),
      );
      await _save();
    }
    if (action == 'delete') {
      page.items.remove(item);
      await _save();
    }
    if (item.productId != null &&
        !products.any((p) => p.id == item.productId)) {
      await _loadCatalog();
    }
    if (mounted) setState(() {});
  }

  Future<void> _manual({DraftPage? page}) async {
    if (editingLocked) return;
    page ??= draft.pages.firstWhere(
      (p) => p.imagePath.isEmpty,
      orElse: () {
        final p = DraftPage(imagePath: '', recognized: true);
        draft.pages.add(p);
        return p;
      },
    );
    // An explicit manual workflow acknowledges processing of this document
    // page, without claiming OCR success or discarding its original evidence.
    if (!page.recognized || page.error != null) {
      page.recognized = true;
      page.error = null;
      page.layoutNote = 'Ръчно въведени позиции. Оригиналната снимка и наличният OCR текст са запазени.';
    }
    final item = DraftItem(requiresCatalogIdentity: true);
    _prepareIdentity(item);
    setState(() => page!.items.add(item));
    await _save();
  }

  bool get _metadataEdited =>
      supplierInput.text.trim() != draft.supplier ||
      documentNumberInput.text.trim() != draft.documentNumber ||
      documentDateInput.text.trim() != draft.documentDate;

  bool _applyMetadata() {
    final supplier = supplierInput.text.trim();
    setState(() {
      error = null;
      draft.supplier = supplier;
      draft.documentNumber = documentNumberInput.text.trim();
      draft.documentDate = documentDateInput.text.trim();
    });
    return true;
  }

  Future<void> _saveMetadata({bool rememberSupplier = false}) async {
    if (editingLocked || !_applyMetadata()) return;
    final supplier = draft.supplier;
    if (await _save() && rememberSupplier) {
      try {
        final prefs = SharedPreferencesAsync();
        final key = 'default_supplier_${draft.ownerId}';
        if (supplier.isEmpty) {
          await prefs.remove(key);
        } else {
          await prefs.setString(key, supplier);
        }
        if (mounted) {
          setState(
            () => status = supplier.isEmpty
                ? 'Доставчикът по подразбиране е изчистен.'
                : 'Доставчикът е запомнен за нови доставки на този телефон.',
          );
        }
      } catch (e) {
        if (mounted) setState(() => error = 'Доставчикът не е запомнен: $e');
      }
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    supplierInput.dispose();
    documentNumberInput.dispose();
    documentDateInput.dispose();
    autosave?.cancel();
    super.dispose();
  }

  void _changed(DraftItem item) {
    _prepareIdentity(item);
    revision++;
    setState(() {
      dirty = true;
      status = 'Има незаписани промени';
    });
    autosave?.cancel();
    autosave = Timer(const Duration(milliseconds: 450), _save);
  }

  Future<void> _removePage(DraftPage page) async {
    if (editingLocked ||
        !await _confirm(
          'Изтрий страница?',
          'Ще се изтрият снимката и ${page.items.length} позиции, включително ${page.items.where((i) => i.checked).length} проверени. Другите страници остават.',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await widget.repository.removePage(draft, page.id);
    } catch (e) {
      if (mounted) setState(() => error = 'Страницата не е изтрита: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _deleteDraft() async {
    if (busy ||
        draft.status != 'draft' ||
        draft.finalizationReceipt != null ||
        !await _confirm(
          'Изтрий чернова?',
          'Ще се изтрият всички снимки, OCR данни и проверки на тази незавършена доставка. Ако е подготвена на сървъра, първо ще се провери и изтрие само незавършеният запис.',
        )) {
      return;
    }
    autosave?.cancel();
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await widget.repository.deleteDraft(
        draft,
        employeeId: PocketBaseService.pb.authStore.record?.id ?? '',
      );
      if (mounted) {
        setState(() {
          busy = false;
          dirty = false;
        });
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Черновата не е изтрита: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _showCorrections() async {
    setState(() => filter = 'unclear');
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !scroll.hasClients) return;
    scroll.jumpTo(0);
    // ListView builds lazily: bring the correction section into the viewport
    // even when a tall document preview precedes it.
    for (var step = 0; mounted && scroll.hasClients && step < 100; step++) {
      await WidgetsBinding.instance.endOfFrame;
      final target = rowsAnchor.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 150),
        );
        return;
      }
      final next = (scroll.offset + scroll.position.viewportDimension * .8)
          .clamp(0.0, scroll.position.maxScrollExtent);
      if (next == scroll.offset) return;
      await scroll.animateTo(
        next,
        duration: const Duration(milliseconds: 60),
        curve: Curves.linear,
      );
    }
  }

  Future<void> _returnToDashboard() async {
    if (!mounted) return;
    setState(() {
      busy = false;
      dirty = false;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Доставката е записана в PocketBase.')),
      );
      Navigator.pop(context, 'finalized');
    }
  }

  Future<void> _finish() async {
    if (busy || confirmingSave) return;
    if (!editingLocked) {
      for (final item in draft.items) {
        if (!item.articleBarcode) _prepareIdentity(item);
      }
    }
    if (!editingLocked && _metadataEdited && !_applyMetadata()) return;
    if (draft.finalizationReceipt == null &&
        draft.stagingRequest == null &&
        draft.finalizationRequest == null &&
        DeliveryFinalization.errors(draft).isNotEmpty) {
      setState(() => error = DeliveryFinalization.errors(draft).join('\n'));
      return;
    }
    if (draft.finalizationReceipt == null &&
        draft.finalizationRequest == null &&
        draft.stagingRequest == null &&
        draft.items.any((i) => parseQuantity(i.received) == 0)) {
      final accepted = draft.items
          .where((i) => (parseQuantity(i.received) ?? 0) > 0)
          .toList();
      final skipped = draft.items
          .where((i) => parseQuantity(i.received) == 0)
          .toList();
      confirmingSave = true;
      bool? confirmed;
      try {
        confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Запази доставката'),
            content: SingleChildScrollView(
              child: Text(
                'Ще бъдат записани ${accepted.length} позиции.\n'
                '${accepted.map((i) => '${i.name}: ${i.received} ${i.unit} • ${i.expiry}').join('\n')}\n\n'
                'Пропуснати: ${skipped.length}\n${skipped.map((i) => i.name).join('\n')}\n\n'
                'Потвърждавам физическата проверка на полученото.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отказ'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Потвърди'),
              ),
            ],
          ),
        );
      } finally {
        confirmingSave = false;
      }
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    autosave?.cancel();
    try {
      if (draft.finalizationReceipt != null) {
        if (await _save()) await _returnToDashboard();
        return;
      }
      // The final Save action confirms all valid rows; OCR never confirms them.
      if (draft.stagingRequest == null && draft.finalizationRequest == null) {
        for (final item in draft.items) {
          item.checked = item.ready;
        }
      }
      // Preserve the corrections even if capability probing or the network fails.
      if (!await _save()) return;
      if (!finalizer.available && widget.finalizer == null) {
        await _probeBackend();
      }
      if (!finalizer.available) throw StateError(backendV2Required);
      await finalizer.prepare(draft, () async {
        if (!await _save()) {
          throw StateError(
            'Промените не са записани на телефона. Повторете след възстановяване на паметта.',
          );
        }
      });
      draft.finalizationRequest ??= {
        ...DeliveryFinalization.request(draft),
        'finalize_by_code': true,
      };
      if (!await _save()) {
        return; // Persist the exact request before any network operation.
      }
      final response = await finalizer.finalize(
        draft.serverId!,
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(draft.finalizationRequest)) as Map,
        ),
      );
      if (response['status'] != 'finalized' ||
          response['delivery_id'] != draft.serverId ||
          response['revision'] is! int ||
          (response['revision'] as int) <=
              (draft.finalizationRequest!['expected_revision'] as int)) {
        throw const FormatException('Няма валидно сървърно потвърждение.');
      }
      draft.finalizationReceipt = Map<String, dynamic>.from(response);
      draft.status = 'finalized';
      draft.serverRevision = response['revision'] as int;
      if (!await _save()) {
        if (mounted) {
          setState(
            () => error = 'Сървърът потвърди доставката, но локалното потвърждение не е записано. Натиснете отново за локално запазване.',
          );
        }
        return;
      }
      await _returnToDashboard();
    } catch (e) {
      if (mounted) setState(() => error = finalizationError(e));
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (error != null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error!)));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final duplicatePages = <int>[];
    for (var i = 1; i < draft.pages.length; i++) {
      if (draft.pages
          .take(i)
          .any((p) => documentMayBeDuplicate(p, draft.pages[i]))) {
        duplicatePages.add(i + 1);
      }
    }
    return PopScope(
      canPop: !busy && !dirty && (editingLocked || !_metadataEdited),
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || busy) return;
        if (!editingLocked && _metadataEdited && !_applyMetadata()) return;
        setState(() => busy = true);
        final saved = await _save();
        if (!mounted) return;
        setState(() => busy = false);
        await WidgetsBinding.instance.endOfFrame;
        if (saved && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Готови ${draft.readyCount} от ${draft.items.length} продукта',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: draft.items.isEmpty
                      ? 0
                      : draft.readyCount / draft.items.length,
                ),
                const SizedBox(height: 8),
                if (!finalizer.available) ...[
                  Text(
                    finalizer is PocketBaseDeliveryFinalizer
                        ? (finalizer as PocketBaseDeliveryFinalizer)
                                  .capabilityProblem ??
                              'Проверява се съвместимостта за финализиране.'
                        : backendV2Required,
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (widget.finalizer == null)
                    TextButton(
                      onPressed: busy ? null : _probeBackend,
                      child: const Text('Провери връзката'),
                    ),
                ],
                if ((draft.stagingRequest != null ||
                        draft.finalizationRequest != null) &&
                    draft.finalizationReceipt == null)
                  const Text(
                    'Има подготвена заявка без потвърден резултат. Данните са заключени; повторението използва същия ключ.',
                    style: TextStyle(fontSize: 12),
                  ),
                if (draft.readyCount < draft.items.length)
                  TextButton(
                    onPressed: busy ? null : _showCorrections,
                    child: Text(
                      'За корекция: ${draft.items.length - draft.readyCount} • Отвори',
                    ),
                  ),
                if (error != null)
                  Text(
                    error!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (draft.documentDate.isNotEmpty &&
                    parseDocumentDate(draft.documentDate) == null)
                  const Text(
                    'Поправете датата на документа или я оставете празна.',
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    key: const Key('finish-delivery'),
                    onPressed: busy
                        ? null
                        : (draft.stagingRequest != null ||
                              draft.finalizationRequest != null ||
                              draft.finalizationReceipt != null ||
                              draft.status == 'draft' &&
                                  DeliveryFinalization.errors(draft).isEmpty)
                        ? _finish
                        : null,
                    icon: busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.task_alt),
                    label: Text(
                      draft.finalizationReceipt != null
                          ? 'Запази потвърждението'
                          : draft.stagingRequest != null ||
                                draft.finalizationRequest != null
                          ? 'Провери приключването'
                          : busy
                          ? 'Записване…'
                          : 'Запази доставката',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        appBar: AppBar(
          title: const Text('Приемане на доставка'),
          actions: [
            IconButton(
              tooltip: 'Запази чернова',
              onPressed: editingLocked ? null : _saveMetadata,
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(
              'Снимайте. Проверете. Запазете черновата.',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              'Получени е предложено от Заявени. Редактирайте при разлика и потвърдете физически. OCR не записва количества в склада.',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: editingLocked ? null : () => _pick(camera: true),
              icon: const Icon(Icons.add_a_photo_outlined),
              label: Text(
                draft.pages.isEmpty ? 'Снимай документ' : 'Снимай още страница',
              ),
            ),
            OutlinedButton.icon(
              onPressed: editingLocked ? null : () => _pick(camera: false),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Избери снимки'),
            ),
            if (busy) const LinearProgressIndicator(),
            Text(status, style: Theme.of(context).textTheme.bodySmall),
            if (error != null)
              SelectableText(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ExpansionTile(
              title: const Text('Данни за документа'),
              subtitle: Text(
                draft.supplier.isEmpty
                    ? 'Доставчик (при нужда)'
                    : draft.supplier,
              ),
              children: [
                TextField(
                  controller: supplierInput,
                  onChanged: (_) => setState(() {}),
                  enabled: !editingLocked,
                  decoration: const InputDecoration(labelText: 'Доставчик'),
                ),
                TextField(
                  controller: documentNumberInput,
                  onChanged: (_) => setState(() {}),
                  enabled: !editingLocked,
                  decoration: const InputDecoration(
                    labelText: 'Номер на документ',
                  ),
                ),
                TextField(
                  controller: documentDateInput,
                  onChanged: (_) => setState(() {}),
                  enabled: !editingLocked,
                  decoration: const InputDecoration(
                    labelText: 'Дата на документа',
                    hintText: 'ДД.ММ.ГГГГ',
                  ),
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: editingLocked ? null : _saveMetadata,
                      child: const Text('Запази данните'),
                    ),
                    TextButton(
                      onPressed: editingLocked
                          ? null
                          : () => _saveMetadata(rememberSupplier: true),
                      child: const Text('Запази и запомни доставчика'),
                    ),
                  ],
                ),
              ],
            ),
            if (catalogError != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      const Text(
                        'Каталогът не е зареден. Сървърът ще провери кодовете при запис.',
                      ),
                      SelectableText(catalogError!),
                      TextButton(
                        onPressed: editingLocked ? null : _loadCatalog,
                        child: const Text('Зареди каталога отново'),
                      ),
                    ],
                  ),
                ),
              ),
            if (duplicatePages.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Възможна повторна снимка: страница ${duplicatePages.join(', ')}. Сравнете снимките и изтрийте повторението.',
                  ),
                ),
              ),
            ExpansionTile(
              title: Text('Страници (${draft.pages.length})'),
              initiallyExpanded: draft.items.isEmpty,
              children: [
                for (final (index, page) in draft.pages.indexed)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            page.imagePath.isEmpty
                                ? 'Ръчни позиции'
                                : 'Страница ${index + 1}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (page.imagePath.isNotEmpty) ...[
                            Image.file(
                              File(page.imagePath),
                              height: 120,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const Text(
                                'Снимката не е достъпна. Снимайте отново.',
                              ),
                            ),
                            Wrap(
                              spacing: 6,
                              children: [
                                TextButton(
                                  onPressed: () => showDocumentPhoto(
                                    context,
                                    page.imagePath,
                                  ),
                                  child: const Text('Преглед'),
                                ),
                                TextButton(
                                  onPressed: editingLocked
                                      ? null
                                      : () => _pick(
                                          camera: true,
                                          replacing: page,
                                        ),
                                  child: const Text('Снимай отново'),
                                ),
                                TextButton(
                                  onPressed: editingLocked
                                      ? null
                                      : () => _pick(
                                          camera: false,
                                          replacing: page,
                                        ),
                                  child: const Text('Замени от галерията'),
                                ),
                                TextButton(
                                  onPressed: editingLocked
                                      ? null
                                      : () => _recognize(only: page),
                                  child: const Text('Разпознай отново'),
                                ),
                              ],
                            ),
                          ],
                          TextButton.icon(
                            onPressed: editingLocked
                                ? null
                                : () => _manual(page: page),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Въведи ръчно за тази страница'),
                          ),
                          TextButton.icon(
                            onPressed: editingLocked
                                ? null
                                : () => _removePage(page),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Изтрий страница'),
                          ),
                          Text(
                            page.error != null
                                ? 'Неуспешно разпознаване: ${page.error}'
                                : page.recognized
                                ? '${page.items.length} позиции'
                                : 'Очаква разпознаване',
                          ),
                          if (page.layoutNote.isNotEmpty)
                            Text(
                              page.layoutNote,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (page.barcodes.isNotEmpty)
                            ExpansionTile(
                              title: Text(
                                'Баркодове на снимката (${page.barcodes.length})',
                              ),
                              subtitle: const Text(
                                'Доказателства към страницата, не продуктови GTIN.',
                              ),
                              children: [
                                for (final barcode in page.barcodes)
                                  ListTile(
                                    title: SelectableText(barcode.value),
                                    subtitle: Text(
                                      barcode.type ?? 'Неопределен тип',
                                    ),
                                  ),
                              ],
                            ),
                          if (page.elapsedMs > 0)
                            Text(
                              'OCR • ${(page.elapsedMs / 1000).toStringAsFixed(1)} сек',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (page.refinements.isNotEmpty)
                            ExpansionTile(
                              title: const Text(
                                'Алтернативни OCR прочити — проверете по снимката',
                              ),
                              children: [
                                for (final retry in page.refinements)
                                  ListTile(
                                    title: SelectableText(
                                      retry['text']?.toString() ?? '',
                                    ),
                                    subtitle: Text(
                                      'Ред: ${retry['box']} • не се прилага автоматично',
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Готови ${draft.readyCount} от ${draft.items.length}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in const {
                  'all': 'Всички',
                  'ready': 'Готови',
                  'unclear': 'За корекция',
                }.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: filter == entry.key,
                    onSelected: (_) => setState(() => filter = entry.key),
                  ),
              ],
            ),
            SizedBox(key: rowsAnchor),
            for (final page in draft.pages)
              for (final item in page.items)
                if (filter == 'all' ||
                    filter == 'ready' && item.ready ||
                    filter == 'unclear' && item.unclear)
                  BulkReviewRow(
                    key: ValueKey(item.id),
                    item: item,
                    enabled: !editingLocked,
                    automaticValidation: true,
                    productLabel: item.productId != null
                        ? 'Разпознат продукт'
                        : item.proposedNewProduct
                        ? 'Нов продукт'
                        : 'Провери кода',
                    productDetail: item.matchReason,
                    onChanged: () => _changed(item),
                    onDetails: () => _editItem(page, item),
                  ),
            if (draft.pages.any(
              (p) =>
                  p.imagePath.isNotEmpty && (!p.recognized || p.error != null),
            ))
              FilledButton.icon(
                onPressed: editingLocked ? null : _recognize,
                icon: const Icon(Icons.text_snippet_outlined),
                label: const Text('Разпознай страниците'),
              ),
            TextButton.icon(
              onPressed: editingLocked ? null : _manual,
              icon: const Icon(Icons.add),
              label: const Text('Добави позиция ръчно'),
            ),
            const SizedBox(height: 16),
            Text(
              draft.allReady
                  ? 'Всички позиции са валидни. Проверете физически количествата и сроковете преди запис.'
                  : 'Коригирайте невалидните позиции преди запис.',
            ),
            const Text(
              '„Запази доставката“ потвърждава получените позиции. Неполучените (0) се запазват само в историята на документа.',
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed:
                  busy ||
                      draft.status != 'draft' ||
                      draft.finalizationReceipt != null
                  ? null
                  : _deleteDraft,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Изтрий чернова'),
            ),
          ],
        ),
      ),
    );
  }
}
