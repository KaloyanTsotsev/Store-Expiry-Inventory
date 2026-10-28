import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/delivery_draft.dart';
import '../services/draft_repository.dart';
import '../services/pocketbase_service.dart';
import '../theme/app_theme.dart';
import 'delivery_editor_screen.dart';

class DeliveriesScreen extends StatefulWidget {
  final bool startNew;
  final VoidCallback? onFinalized;
  const DeliveriesScreen({super.key, this.startNew = false, this.onFinalized});
  @override
  State<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

class _DeliveriesScreenState extends State<DeliveriesScreen> {
  final repository = DraftRepository();
  List<DeliveryDraft> drafts = [];
  String? error;
  bool loading = true, opening = false;
  String get ownerId => PocketBaseService.pb.authStore.record!.id;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final recovered = await repository.recoverPicker(ownerId, ImagePicker());
      await _load();
      if (!mounted) return;
      if (recovered != null) {
        await _open(recovered);
      } else if (widget.startNew) {
        await _create();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    }
  }

  Future<void> _load() async {
    try {
      final records = (await repository.list(ownerId))
          .where((draft) => draft.status == 'draft')
          .toList();
      if (mounted) {
        setState(() {
          drafts = records;
          error = null;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = 'Черновите не са заредени: $e';
          loading = false;
        });
      }
    }
  }

  Future<void> _create() async {
    if (opening) return;
    setState(() => opening = true);
    try {
      final draft = DeliveryDraft(ownerId: ownerId);
      await repository.save(draft);
      if (mounted) await _open(draft, camera: true);
    } catch (e) {
      if (mounted) setState(() => error = 'Черновата не е създадена: $e');
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  Future<void> _open(DeliveryDraft draft, {bool camera = false}) async {
    if (opening && !camera) return;
    setState(() => opening = true);
    try {
      final result = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => DeliveryEditorScreen(
            draft: draft,
            repository: repository,
            startCamera: camera,
          ),
        ),
      );
      if (mounted && result == 'finalized') {
        if (widget.startNew) {
          Navigator.pop(context, 'finalized');
        } else {
          widget.onFinalized?.call();
        }
        return;
      }
      if (mounted) await _load();
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  Future<void> _delete(DeliveryDraft draft) async {
    if (opening) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Изтрий чернова?'),
        content: Text(
          'Ще се изтрият ${draft.pages.length} снимки/страници, OCR данните и всички проверки от този телефон.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отказ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Изтрий'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => opening = true);
    try {
      await repository.deleteDraft(draft, employeeId: ownerId);
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = 'Черновата не е изтрита: $e');
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Доставки'), actions: const [ThemeMenu()]),
    body: RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'От документа до проверена доставка',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'Черновите и снимките се пазят на този телефон за вашия служебен профил.',
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: opening ? null : _create,
            icon: const Icon(Icons.document_scanner_outlined),
            label: const Text('Сканирай доставка'),
          ),
          const SizedBox(height: 24),
          Text(
            'Незавършени доставки',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
          if (error != null) ...[
            SelectableText(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            TextButton(onPressed: _load, child: const Text('Опитай отново')),
          ],
          if (!loading && error == null && drafts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('Нямате чернови. Започнете със снимка на документа.'),
            ),
          for (final draft in drafts)
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: const Icon(Icons.edit_document),
                title: Text(
                  draft.supplier.isEmpty
                      ? 'Доставка без доставчик'
                      : draft.supplier,
                ),
                subtitle: Text(
                  '${draft.pages.length} стр. • Проверени ${draft.checkedCount} от ${draft.items.length}\n'
                  '${draft.documentNumber.isEmpty ? 'Без номер' : draft.documentNumber} • Чернова',
                ),
                trailing: IconButton(
                  tooltip: 'Изтрий чернова',
                  onPressed:
                      opening ||
                          draft.status != 'draft' ||
                          draft.finalizationRequest != null ||
                          draft.stagingRequest != null
                      ? null
                      : () => _delete(draft),
                  icon: const Icon(Icons.delete_outline),
                ),
                onTap: opening ? null : () => _open(draft),
              ),
            ),
        ],
      ),
    ),
  );
}
