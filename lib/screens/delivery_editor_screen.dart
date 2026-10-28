import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

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
import '../services/product_catalog_service.dart';
import '../services/delivery_catalog_service.dart';
import '../services/delivery_row_status.dart';
import '../services/delivery_finalization_service.dart';
import 'delivery_item_screen.dart';

class DeliveryEditorScreen extends StatefulWidget {
  final DeliveryDraft draft;
  final DraftRepository repository;
  final bool startCamera;
  final OcrEngine? engine;
  final PageCapture? capture;
  final DeliveryFinalizer? finalizer;
  final ProductCatalogService? catalog;
  final Future<List<RecordModel>> Function()? catalogLoader;
  const DeliveryEditorScreen({
    super.key,
    required this.draft,
    required this.repository,
    this.startCamera = false,
    this.engine,
    this.capture,
    this.finalizer,
    this.catalog,
    this.catalogLoader,
  });
  @override
  State<DeliveryEditorScreen> createState() => _DeliveryEditorScreenState();
}

class _DeliveryEditorScreenState extends State<DeliveryEditorScreen> {
  late final capture = widget.capture ?? PageCaptureService();
  final parser = PaddleDocumentAdapter();
  bool busy = false;
  bool confirmingFinalization = false;
  bool catalogLoaded = false, dirty = false;
  String filter = 'all';
  Timer? autosave;
  int revision = 0;
  String? error;
  String status = 'Черновата е записана на телефона';
  List<RecordModel> products = [];
  late final catalog = widget.catalog ?? ProductCatalogService();
  CatalogAccess catalogAccess = const CatalogAccess(
    available: false,
    message: 'Проверява се Catalog V3…',
  );
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
    final allowed =
        catalogAccess.available && catalogAccess.canFinalizeDelivery;
    if (item.catalogOnFinalize != allowed && item.productId == null) {
      item.checked = false;
    }
    item.catalogOnFinalize = allowed;
    ProductMatcher.prepare(item, products, draft.supplier);
  }

  Future<void> _loadCatalog() async {
    if (draft.stagingRequest != null ||
        draft.finalizationRequest != null ||
        draft.status != 'draft') {
      return;
    }
    try {
      final access = await catalog.probe();
      if (!mounted) return;
      setState(() => catalogAccess = access);
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
          catalogLoaded = true;
          for (final item in draft.items) {
            _prepareIdentity(item);
          }
        });
        await _save();
      }
    } catch (e) {
      PocketBaseService.logError('delivery.catalog', e);
      if (mounted) {
        setState(() => catalogError = PocketBaseService.errorMessage(e));
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
          if (catalogLoaded) {
            for (final item in page.items) {
              _prepareIdentity(item);
            }
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
          catalogAccess: catalogAccess,
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
    page.items.add(item);
    if (await _save() && mounted) await _editItem(page, item);
  }

  Future<void> _metadata() async {
    if (editingLocked) return;
    final supplier = TextEditingController(text: draft.supplier);
    final number = TextEditingController(text: draft.documentNumber);
    final date = TextEditingController(text: draft.documentDate);
    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Данни за документа'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: supplier,
                  decoration: const InputDecoration(labelText: 'Доставчик'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: number,
                  decoration: const InputDecoration(
                    labelText: 'Номер на документ',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: date,
                  decoration: const InputDecoration(
                    labelText: 'Дата на документа',
                    hintText: 'ДД.ММ.ГГГГ',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отказ'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Запази'),
            ),
          ],
        ),
      );
      if (saved == true) {
        if (draft.supplier != supplier.text.trim()) {
          if (draft.items.any((item) => item.catalogRequest != null)) {
            if (mounted) {
              setState(
                () => error = 'Първо разрешете запазената каталожна заявка, преди да сменяте доставчика.',
              );
            }
            return;
          }
          for (final item in draft.items) {
            item.checked = false;
            item.productId = null;
            item.proposedNewProduct = false;
            item.productSelectionConfirmed = false;
          }
        }
        draft.supplier = supplier.text.trim();
        if (catalogLoaded) {
          for (final item in draft.items) {
            _prepareIdentity(item);
          }
        }
        draft.documentNumber = number.text.trim();
        draft.documentDate = date.text.trim();
        await _save();
      }
    } finally {
      supplier.dispose();
      number.dispose();
      date.dispose();
    }
  }

  @override
  void dispose() {
    autosave?.cancel();
    super.dispose();
  }

  void _changed(DraftItem item) {
    if (catalogLoaded) _prepareIdentity(item);
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
    if (editingLocked ||
        !await _confirm(
          'Изтрий чернова?',
          'Ще се изтрият всички снимки, OCR данни и проверки на тази незавършена доставка от телефона.',
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

  DeliveryRowStatus _rowStatus(DraftItem item) => DeliveryRowStatus.resolve(
    item,
    draft.supplier,
    catalogLoaded,
    catalogAccess,
  );

  Future<void> _addCatalog(DraftItem item) async {
    if (editingLocked || !_rowStatus(item).canAdd) return;
    setState(() => busy = true);
    try {
      final access = await catalog.probe();
      if (!mounted) return;
      setState(() => catalogAccess = access);
      if (!access.available || !access.canCreate) {
        throw StateError(access.message);
      }
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Добави в каталога'),
          content: Text(
            '${item.name}\nДоставчик: ${draft.supplier}\nКод: ${item.supplierCode}\n\nПотвърждавам името и кода. Това не записва количества и не потвърждава физическата проверка.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отказ'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Потвърди добавянето'),
            ),
          ],
        ),
      );
      if (approved != true) return;
      final record = await DeliveryCatalogService(catalog: catalog).confirm(
        item: item,
        supplier: draft.supplier,
        products: products,
        physicallyConfirmed: true,
        catalogOnly: true,
        persist: () async {
          item.checked = false;
          if (!await _save()) throw StateError('Черновата не е записана.');
        },
      );
      products = [...products.where((p) => p.id != record.id), record];
      for (final row in draft.items) {
        _prepareIdentity(row);
      }
      await _save();
    } catch (e) {
      if (mounted) setState(() => error = ProductCatalogService.message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _markAll() async {
    if (editingLocked) return;
    var physicallyChecked = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Маркирай всички като проверени'),
          content: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: physicallyChecked,
            title: const Text(
              'Физически проверих продуктите, количествата и сроковете на всички позиции. Партида N/A не изисква отделна проверка.',
            ),
            onChanged: (value) =>
                update(() => physicallyChecked = value == true),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отказ'),
            ),
            FilledButton(
              onPressed: physicallyChecked
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('Потвърди всички'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      for (final item in draft.items) {
        item.checked = item.validationErrors.isEmpty;
      }
    });
    await _save();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Проверени ${draft.checkedCount} от ${draft.items.length}. Невалидните позиции остават за корекция.',
          ),
        ),
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
    if (mounted) Navigator.pop(context, 'finalized');
  }

  Future<void> _finish() async {
    if (busy) return;
    if (draft.finalizationReceipt == null &&
        draft.stagingRequest == null &&
        draft.finalizationRequest == null &&
        DeliveryFinalization.errors(draft).isNotEmpty) {
      return;
    }
    setState(() {
      busy = true;
      confirmingFinalization = true;
      error = null;
    });
    autosave?.cancel();
    try {
      if (draft.finalizationReceipt != null) {
        if (await _save()) await _returnToDashboard();
        return;
      }
      final lines =
          (draft.finalizationRequest?['lines'] ??
                  draft.stagingRequest?['lines'])
              as List? ??
          DeliveryFinalization.lines(draft);
      final approved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Приключване на доставката'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Позиции: ${lines.length}'),
                  const Text(
                    'Разлика = получени − заявени. Количествата са показани по позиции.',
                  ),
                  const SizedBox(height: 12),
                  for (final raw in lines) ...[
                    Text(
                      raw['name'] as String,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Заявени: ${raw['requested_quantity']} • Получени: ${raw['received_quantity']}',
                    ),
                    Text(
                      'Разлика: ${DeliveryFinalization.differenceText(raw['received_quantity'] as num, raw['requested_quantity'] as num)}',
                    ),
                    Text(
                      'Годност: ${raw['expiry_date']} • Партида: ${raw['lot_number']}',
                    ),
                    const Divider(),
                  ],
                  if (!finalizer.available) const Text(backendV2Required),
                  if (finalizer.available)
                    const Text(
                      'Потвърждавам имената и артикулните кодове на новите продукти, физически получените количества, сроковете и партидите. Новите продукти и асоциации се създават заедно с партидите и входящите движения.',
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Назад към проверката'),
            ),
            FilledButton(
              onPressed: finalizer.available
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('Потвърди и приключи'),
            ),
          ],
        ),
      );
      if (mounted) setState(() => confirmingFinalization = false);
      if (approved != true) {
        await _save();
        return;
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
        if (draft.items.any(
          (i) => i.requiresCatalogIdentity && i.catalogOnFinalize,
        ))
          'catalog_confirmed': true,
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
        setState(() {
          busy = false;
          confirmingFinalization = false;
        });
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
      canPop: !busy && !dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || busy) return;
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
                  'Проверени ${draft.checkedCount} от ${draft.items.length} продукта',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: draft.items.isEmpty
                      ? 0
                      : draft.checkedCount / draft.items.length,
                ),
                const SizedBox(height: 8),
                if (!finalizer.available)
                  const Text(
                    'Реалното финализиране изисква backend V2.',
                    style: TextStyle(fontSize: 12),
                  ),
                if ((draft.stagingRequest != null ||
                        draft.finalizationRequest != null) &&
                    draft.finalizationReceipt == null)
                  const Text(
                    'Има подготвена заявка без потвърден резултат. Данните са заключени; повторението използва същия ключ.',
                    style: TextStyle(fontSize: 12),
                  ),
                if (!draft.allReviewed)
                  const Text(
                    'Проверете всички продукти, получени количества и срокове.',
                    style: TextStyle(fontSize: 12),
                  ),
                if (draft.items.any((i) => parseQuantity(i.ordered) == null))
                  const Text(
                    'Коригирайте заявените количества.',
                    style: TextStyle(fontSize: 12),
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
                    icon: busy && !confirmingFinalization
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
                          : 'Приключи доставката',
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
              tooltip: 'Данни за документа',
              onPressed: editingLocked ? null : _metadata,
              icon: const Icon(Icons.edit_note),
            ),
            IconButton(
              tooltip: 'Запази чернова',
              onPressed: editingLocked ? null : _save,
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: ListView(
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
            if (busy && !confirmingFinalization)
              const LinearProgressIndicator(),
            Text(status, style: Theme.of(context).textTheme.bodySmall),
            if (error != null)
              SelectableText(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (!catalogAccess.available || !catalogAccess.canCreate)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(catalogAccess.message),
                ),
              ),
            if (draft.supplier.trim().isEmpty && draft.items.isNotEmpty)
              OutlinedButton.icon(
                onPressed: editingLocked ? null : _metadata,
                icon: const Icon(Icons.local_shipping_outlined),
                label: const Text('Попълни доставчик за документа'),
              ),
            if (catalogError != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      const Text(
                        'Каталогът не е зареден. Изборът на продукт остава непотвърден.',
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
              'Проверени ${draft.checkedCount} от ${draft.items.length}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in const {
                  'all': 'Всички',
                  'unchecked': 'Непроверени',
                  'unclear': 'Неясни',
                }.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: filter == entry.key,
                    onSelected: (_) => setState(() => filter = entry.key),
                  ),
              ],
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed:
                  editingLocked ||
                      !draft.items.any((i) => i.validationErrors.isEmpty)
                  ? null
                  : _markAll,
              icon: const Icon(Icons.done_all),
              label: const Text('Маркирай всички — проверени'),
            ),
            for (final page in draft.pages)
              for (final item in page.items)
                if (filter == 'all' ||
                    filter == 'unchecked' && !item.checked ||
                    filter == 'unclear' && item.unclear)
                  BulkReviewRow(
                    key: ValueKey(item.id),
                    item: item,
                    enabled: !editingLocked,
                    productLabel: _rowStatus(item).label,
                    productDetail: _rowStatus(item).detail,
                    detailsLabel: _rowStatus(item).action,
                    onAddCatalog: _rowStatus(item).canAdd
                        ? () => _addCatalog(item)
                        : null,
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
              draft.allReviewed
                  ? 'Всички позиции са проверени. Доставката е готова за приключване.'
                  : 'Проверете всички позиции преди финализиране.',
            ),
            const Text(
              'Каталожният запис не променя количества. Партиди и входящи движения се записват само чрез „Приключи доставката“.',
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: editingLocked || draft.status != 'draft'
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
