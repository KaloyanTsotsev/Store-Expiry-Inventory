import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../models/delivery_draft.dart';
import '../widgets/expiry_date_field.dart';
import '../services/delivery_finalization_service.dart';
import '../services/draft_repository.dart';
import '../services/pocketbase_service.dart';

class KnownProductBatchScreen extends StatefulWidget {
  const KnownProductBatchScreen({
    super.key,
    required this.ownerId,
    this.lookup,
    this.repository,
    this.finalizer,
  });
  final String ownerId;
  final Future<RecordModel?> Function(String)? lookup;
  final DraftRepository? repository;
  final DeliveryFinalizer? finalizer;

  @override
  State<KnownProductBatchScreen> createState() =>
      _KnownProductBatchScreenState();
}

class _KnownProductBatchScreenState extends State<KnownProductBatchScreen> {
  final barcode = TextEditingController(),
      expiry = TextEditingController(),
      quantity = TextEditingController(),
      lot = TextEditingController();
  late final repository = widget.repository ?? DraftRepository();
  late final finalizer = widget.finalizer ?? PocketBaseDeliveryFinalizer();
  RecordModel? product;
  DeliveryDraft? draft;
  bool busy = false;
  String? error;

  @override
  void dispose() {
    for (final controller in [barcode, expiry, quantity, lot]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _lookup() async {
    if (busy || draft != null || barcode.text.trim().isEmpty) return;
    setState(() {
      busy = true;
      product = null;
      error = null;
    });
    try {
      final found =
          await (widget.lookup ?? PocketBaseService.findProductByBarcode)(
            barcode.text.trim(),
          );
      if (!mounted) return;
      setState(() {
        if (found == null) {
          error = 'Няма продукт с този баркод в PocketBase. Проверете кода или добавете продукта веднъж от „Продукти“.';
        } else {
          product = found;
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = PocketBaseService.errorMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save() async {
    if (busy || product == null) return;
    if (draft == null &&
        (parseDocumentDate(expiry.text) == null ||
            (parseQuantity(quantity.text) ?? 0) <= 0 ||
            lot.text.trim().length > 128)) {
      setState(
        () => error = 'Въведете валиден срок, положително количество и партида до 128 знака.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final selected = product!;
      final pending = draft ??= DeliveryDraft(
        ownerId: widget.ownerId,
        pages: [
          DraftPage(
            imagePath: '',
            recognized: true,
            items: [
              DraftItem(
                name: selected.getStringValue('name'),
                barcode: selected.getStringValue('barcode'),
                productId: selected.id,
                productSelectionConfirmed: true,
                expiry: expiry.text.trim(),
                ordered: quantity.text.trim(),
                received: quantity.text.trim(),
                lot: lot.text,
                checked: true,
              ),
            ],
          ),
        ],
      );
      await repository.save(pending);
      if (pending.finalizationReceipt == null) {
        if (widget.finalizer == null) {
          await (finalizer as PocketBaseDeliveryFinalizer).probe();
        }
        if (!finalizer.available) throw StateError(backendV2Required);
        await finalizer.prepare(pending, () => repository.save(pending));
        pending.finalizationRequest ??= DeliveryFinalization.request(pending);
        await repository.save(pending);
        final receipt = await finalizer.finalize(
          pending.serverId!,
          pending.finalizationRequest!,
        );
        pending.finalizationReceipt = receipt;
        pending.status = 'finalized';
        pending.serverRevision = receipt['revision'] as int;
      }
      await repository.save(pending);
      if (!mounted) return;
      setState(() => busy = false);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = finalizationError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Добави срок по баркод')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: barcode,
            enabled: !busy && draft == null,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _lookup(),
            onChanged: (_) => setState(() {
              product = null;
              error = null;
            }),
            decoration: const InputDecoration(labelText: 'Баркод'),
          ),
          OutlinedButton(
            onPressed: busy || draft != null ? null : _lookup,
            child: const Text('Намери в PocketBase'),
          ),
          if (product case final selected?) ...[
            Text(
              selected.getStringValue('name'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text('Баркод: ${selected.getStringValue('barcode')}'),
            ExpiryDateField(
              controller: expiry,
              enabled: !busy && draft == null,
            ),
            TextField(
              controller: quantity,
              enabled: !busy && draft == null,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Количество'),
            ),
            TextField(
              controller: lot,
              enabled: !busy && draft == null,
              decoration: const InputDecoration(
                labelText: 'Партида (по избор)',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Проверете физически срока и количеството, преди да запишете.',
            ),
            FilledButton(
              onPressed: busy ? null : _save,
              child: Text(
                draft == null
                    ? 'Потвърди и запиши срока'
                    : 'Провери записа отново',
              ),
            ),
          ],
          if (busy) const LinearProgressIndicator(),
          if (error != null) SelectableText(error!),
        ],
      ),
    ),
  );
}
