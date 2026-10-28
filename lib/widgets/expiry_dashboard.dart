import 'package:flutter/material.dart';

import 'storeflow_brand.dart';

import '../models/expiry_batch.dart';
import '../services/batch_check_repository.dart';
import '../services/pocketbase_service.dart';
import '../theme/app_spacing.dart';
import 'expiry_batch_card.dart';

enum _BatchFilter { all, expired, soon }

class ExpiryDashboard extends StatefulWidget {
  final String ownerId, employeeName;
  final VoidCallback? onScan, onDrafts;
  final Future<List<ExpiryBatch>> Function()? loadBatches;
  final BatchCheckRepository? checkRepository;
  const ExpiryDashboard({
    super.key,
    required this.ownerId,
    required this.employeeName,
    this.onScan,
    this.onDrafts,
    this.loadBatches,
    this.checkRepository,
  });
  @override
  State<ExpiryDashboard> createState() => ExpiryDashboardState();
}

class ExpiryDashboardState extends State<ExpiryDashboard>
    with WidgetsBindingObserver {
  late final repository = widget.checkRepository ?? BatchCheckRepository();
  List<ExpiryBatch> batches = [];
  List<Map<String, dynamic>> pending = [];
  bool loading = true, acting = false;
  int refreshVersion = 0;
  final searchController = TextEditingController();
  _BatchFilter _filter = _BatchFilter.all;
  bool earliestFirst = true;
  String? error;
  DateTime? loadedAt;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  @override
  void dispose() {
    searchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    final version = ++refreshVersion;
    if (!loading && mounted) setState(() => loading = true);
    try {
      final records =
          await (widget.loadBatches?.call() ??
              PocketBaseService.getExpiryBatches());
      final commands = await repository.list(widget.ownerId);
      if (mounted && version == refreshVersion) {
        setState(() {
          batches = records.where((b) => !b.closed).toList()
            ..sort(
              (a, b) => (a.days ?? 0x7fffffff).compareTo(b.days ?? 0x7fffffff),
            );
          pending = commands;
          error = null;
          loadedAt = DateTime.now();
        });
      }
    } catch (e) {
      PocketBaseService.logError('batches.dashboard', e);
      if (mounted && version == refreshVersion) {
        setState(() => error = PocketBaseService.errorMessage(e));
      }
    } finally {
      if (mounted && version == refreshVersion) setState(() => loading = false);
    }
  }

  Future<void> _action(ExpiryBatch batch, String kind) async {
    if (acting) return;
    setState(() => acting = true);
    final quantity = TextEditingController(text: kind == 'none' ? '0' : '');
    final reason = TextEditingController();
    try {
      var validation = '';
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text(
              kind == 'none'
                  ? 'Няма останали'
                  : kind == 'waste'
                  ? 'Потвърди бракуване'
                  : 'Има останали',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${batch.productName}\nПартида: ${batch.lot}'),
                  const SizedBox(height: 12),
                  const Text(
                    'Ще се запази неизпратена заявка на този телефон. Сървърната история и предупрежденията остават непроменени до синхронизация.',
                  ),
                  if (kind != 'none') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: quantity,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: kind == 'waste'
                            ? 'Действително бракувано количество'
                            : 'Физически преброени бройки',
                      ),
                    ),
                  ],
                  if (kind == 'waste') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: reason,
                      decoration: const InputDecoration(
                        labelText: 'Причина за бракуване',
                      ),
                    ),
                  ],
                  if (validation.isNotEmpty)
                    Text(
                      validation,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
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
                onPressed: () async {
                  // Repository also validates; dialog remains open for correction.
                  final count = double.tryParse(
                    quantity.text.trim().replaceAll(',', '.'),
                  );
                  if (count == null ||
                      !count.isFinite ||
                      (kind != 'none' && count <= 0) ||
                      (kind == 'waste' && reason.text.trim().isEmpty)) {
                    update(
                      () => validation =
                          'Въведете положително количество и причина при брак.',
                    );
                    return;
                  }
                  Navigator.pop(context, true);
                },
                child: const Text('Потвърди и запази заявка'),
              ),
            ],
          ),
        ),
      );
      if (approved == true) {
        await repository.prepare(
          owner: widget.ownerId,
          batch: batch,
          kind: kind,
          quantity: quantity.text,
          reason: reason.text,
        );
        final commands = await repository.list(widget.ownerId);
        if (mounted) setState(() => pending = commands);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Заявката не е записана: $e')));
      }
    } finally {
      // Modal text fields are unmounted after their closing animation.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      quantity.dispose();
      reason.dispose();
      if (mounted) setState(() => acting = false);
    }
  }

  Future<void> _cancel(Map<String, dynamic> command) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Отмени неизпратената заявка?'),
        content: const Text('Няма да се променят сървърни записи.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Назад'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Отмени заявката'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await repository.cancel(
        widget.ownerId,
        command['operation_key'] as String,
      );
      final commands = await repository.list(widget.ownerId);
      if (mounted) setState(() => pending = commands);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = searchController.text.trim().toLowerCase();
    final visible =
        batches.where((batch) {
          final state = ExpiryState.of(batch);
          return batch.productName.toLowerCase().contains(query) &&
              switch (_filter) {
                _BatchFilter.all => true,
                _BatchFilter.expired => state == ExpiryState.expired,
                _BatchFilter.soon => state == ExpiryState.soon,
              };
        }).toList()..sort((a, b) {
          // Unknown dates stay last in either direction.
          if (a.days == null) return b.days == null ? a.id.compareTo(b.id) : 1;
          if (b.days == null) return -1;
          final result = earliestFirst
              ? a.days!.compareTo(b.days!)
              : b.days!.compareTo(a.days!);
          return result == 0 ? a.productName.compareTo(b.productName) : result;
        });
    final unknown = batches.where((b) => b.days == null).length;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: RefreshIndicator(
          onRefresh: refresh,
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.large,
                  AppSpacing.small,
                  AppSpacing.large,
                  AppSpacing.large,
                ),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Здравей, ${widget.employeeName}!',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.small),
                      Text(
                        'Срокове на годност',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Text(storeFlowTagline),
                      const SizedBox(height: AppSpacing.large),
                      Wrap(
                        spacing: AppSpacing.small,
                        runSpacing: AppSpacing.small,
                        children: [
                          FilledButton.icon(
                            onPressed: widget.onScan,
                            icon: const Icon(Icons.document_scanner_outlined),
                            label: const Text('Сканирай доставка'),
                          ),
                          OutlinedButton(
                            onPressed: widget.onDrafts,
                            child: const Text('Чернови'),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.large),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Обзор на партидите',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Обнови партидите',
                            onPressed: loading ? null : refresh,
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                      if (loading)
                        const Padding(
                          padding: EdgeInsets.only(bottom: AppSpacing.medium),
                          child: LinearProgressIndicator(),
                        ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: AppSpacing.medium,
                          ),
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.large),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    loadedAt == null
                                        ? 'Партидите не са заредени.'
                                        : 'Обновяването е неуспешно. Показани са последните заредени данни.',
                                  ),
                                  const SizedBox(height: AppSpacing.small),
                                  SelectableText(error!),
                                  TextButton(
                                    onPressed: loading ? null : refresh,
                                    child: const Text('Опитай отново'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ExpirySummary(batches: batches, loaded: loadedAt != null),
                      if (unknown > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.small),
                          child: Text(
                            '$unknown ${unknown == 1 ? 'партида' : 'партиди'} без валидна дата — за проверка',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      const SizedBox(height: AppSpacing.medium),
                      Text(
                        'Количествата са от доставките, не текуща наличност.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (loadedAt != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Обновено ${loadedAt!.hour.toString().padLeft(2, '0')}:${loadedAt!.minute.toString().padLeft(2, '0')}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      const SizedBox(height: AppSpacing.section),
                      TextField(
                        key: const ValueKey('batch-search'),
                        controller: searchController,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: 'Търси продукт',
                          hintText: 'Име на продукт',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Изчисти търсенето',
                                  onPressed: () =>
                                      setState(searchController.clear),
                                  icon: const Icon(Icons.close),
                                ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.medium),
                      Wrap(
                        spacing: AppSpacing.small,
                        runSpacing: 4,
                        children: [
                          for (final entry in {
                            _BatchFilter.all: 'Всички',
                            _BatchFilter.expired: 'Просрочени',
                            _BatchFilter.soon: 'Скоро',
                          }.entries)
                            FilterChip(
                              key: ValueKey('filter-${entry.key.name}'),
                              tooltip: entry.key == _BatchFilter.soon
                                  ? 'Скоро изтичащи'
                                  : entry.value,
                              label: Text(entry.value),
                              selected: _filter == entry.key,
                              onSelected: (_) =>
                                  setState(() => _filter = entry.key),
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.small),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: AppSpacing.medium,
                        children: [
                          Text(
                            loadedAt == null
                                ? 'Партиди'
                                : '${visible.length} от ${batches.length} партиди',
                            style: theme.textTheme.titleMedium,
                          ),
                          TextButton.icon(
                            key: const ValueKey('batch-sort'),
                            onPressed: () =>
                                setState(() => earliestFirst = !earliestFirst),
                            icon: Icon(
                              earliestFirst
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward,
                              size: 18,
                            ),
                            label: Text(
                              earliestFirst
                                  ? 'Най-ранен срок'
                                  : 'Най-късен срок',
                            ),
                          ),
                        ],
                      ),
                      if (loadedAt != null && visible.isEmpty && !loading)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.section,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.inventory_2_outlined, size: 32),
                              const SizedBox(height: AppSpacing.medium),
                              Text(
                                batches.isEmpty
                                    ? 'Няма видими активни партиди.'
                                    : 'Няма партиди по тези критерии.',
                                style: theme.textTheme.titleMedium,
                              ),
                              if (batches.isNotEmpty)
                                TextButton(
                                  onPressed: () => setState(() {
                                    searchController.clear();
                                    _filter = _BatchFilter.all;
                                  }),
                                  child: const Text('Покажи всички'),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.large,
                  0,
                  AppSpacing.large,
                  AppSpacing.section,
                ),
                sliver: SliverList.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.medium),
                  itemBuilder: (context, index) {
                    final batch = visible[index];
                    final commands = pending.where(
                      (p) => p['batch'] == batch.id,
                    );
                    return ExpiryBatchCard(
                      key: ValueKey('batch-${batch.id}'),
                      batch: batch,
                      actions: commands.isNotEmpty
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Неизпратена проверка на този телефон. Не е отразена в PocketBase.',
                                ),
                                TextButton(
                                  onPressed: () => _cancel(commands.first),
                                  child: const Text(
                                    'Отмени неизпратената заявка',
                                  ),
                                ),
                              ],
                            )
                          : Wrap(
                              spacing: AppSpacing.small,
                              children: [
                                TextButton(
                                  onPressed: acting
                                      ? null
                                      : () => _action(batch, 'none'),
                                  child: const Text('Няма останали'),
                                ),
                                TextButton(
                                  onPressed: acting
                                      ? null
                                      : () => _action(batch, 'count'),
                                  child: const Text('Има останали'),
                                ),
                                TextButton(
                                  onPressed: acting
                                      ? null
                                      : () => _action(batch, 'waste'),
                                  child: const Text('Бракуване'),
                                ),
                              ],
                            ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
