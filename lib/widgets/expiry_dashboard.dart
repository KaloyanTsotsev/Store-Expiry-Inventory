import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import 'storeflow_brand.dart';

import '../models/expiry_batch.dart';
import '../services/batch_check_repository.dart';
import '../services/pocketbase_service.dart';
import '../theme/app_spacing.dart';
import 'expiry_batch_card.dart';

enum _BatchFilter { all, expired, soon }

class ExpiryDashboard extends StatefulWidget {
  final String ownerId, employeeName;
  final VoidCallback? onScan, onDrafts, onAddBatch;
  final Future<List<ExpiryBatch>> Function()? loadBatches;
  final BatchCheckRepository? checkRepository;
  final Future<void> Function(String, Map<String, dynamic>)? sendHandling;
  final Future<void> Function()? checkHandlingCapability;
  const ExpiryDashboard({
    super.key,
    required this.ownerId,
    required this.employeeName,
    this.onScan,
    this.onDrafts,
    this.onAddBatch,
    this.loadBatches,
    this.checkRepository,
    this.sendHandling,
    this.checkHandlingCapability,
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
  Future<void>? _refreshing;
  int refreshVersion = 0;
  final searchController = TextEditingController();
  _BatchFilter _filter = _BatchFilter.all;
  bool earliestFirst = true;
  String? error, syncError;
  DateTime? loadedAt;
  Timer? _poll;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _pollBatches());
  }

  @override
  void dispose() {
    searchController.dispose();
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> _pollBatches() async {
    if (!mounted ||
        acting ||
        loading ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
      return;
    }
    final version = refreshVersion;
    try {
      final records =
          await (widget.loadBatches?.call() ??
              PocketBaseService.getExpiryBatches(includeClosed: true));
      await _clearConfirmedClosed(records);
      if (mounted && !acting && !loading && version == refreshVersion) {
        setState(() {
          batches = records.where((b) => !b.closed).toList();
          loadedAt = DateTime.now();
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = PocketBaseService.errorMessage(e));
    }
  }

  String _handlingError(Object e) {
    if (e is ClientException) {
      if (e.response['code'] == 'incompatible_batch_dependency' ||
          e.response['code'] == 'unsupported_batch_dependency') {
        return 'Партидата има несъвместима зависимост. Нищо не е изтрито; необходим е преглед на свързаната схема.';
      }
      if (e.response['code'] == 'batch_deletion_confirmation_required') {
        return 'Необходимо е ново изрично потвърждение за окончателно изтриване. Обновете приложението.';
      }
      if (e.response['code'] == 'batch_deletion_not_confirmed') {
        return 'Окончателното изтриване не е потвърдено. Данните са запазени; опитайте отново със същата заявка.';
      }
      if (e.statusCode == 404 && e.response['code'] == 'batch_not_found') {
        return 'Партидата вече не е достъпна. Опреснете списъка и проверете записа.';
      }
      if (e.statusCode == 404) {
        return 'На сървъра липсва маршрутът за премахване на партида. Необходимо е качване на expiry_handling.pb.js и lib/handle_expiry.js.';
      }
      if (e.statusCode == 401 || e.statusCode == 403) {
        return 'Сесията е изтекла или нямате права. Влезте отново преди повторен опит.';
      }
      if (e.statusCode == 409) {
        return 'Партидата е променена. Опреснете списъка, отменете старата заявка и потвърдете актуалния запис.';
      }
      if (e.statusCode == 503) {
        return 'Маршрутът не потвърждава защитената схема за приключване на партиди.';
      }
    }
    return PocketBaseService.errorMessage(e);
  }

  Future<void> _retry(Map<String, dynamic> command) async {
    if (acting || loading) return;
    await repository.setRetry(
      widget.ownerId,
      command['operation_key'] as String,
    );
    if (mounted) await refresh();
  }

  Future<void> _clearConfirmedClosed(List<ExpiryBatch> records) async {
    final closed = records.where((b) => b.closed).map((b) => b.id).toSet();
    if (closed.isEmpty) return;
    final commands = await repository.list(widget.ownerId);
    for (final command in commands.where(
      (c) => c['kind'] == 'handled' && closed.contains(c['batch']),
    )) {
      await repository.cancel(
        widget.ownerId,
        command['operation_key'] as String,
      );
    }
    final remaining = await repository.list(widget.ownerId);
    if (mounted) {
      setState(() {
        pending = remaining;
        syncError = remaining
            .map((c) => c['sync_error'])
            .whereType<String>()
            .firstOrNull;
      });
    }
  }

  Future<void> refresh() async {
    if (acting) return;
    await _refresh();
  }

  Future<void> _refresh() =>
      _refreshing ??= _loadAndSync().whenComplete(() => _refreshing = null);

  Future<void> _loadAndSync() async {
    final version = ++refreshVersion;
    if (!loading && mounted) setState(() => loading = true);
    try {
      final commands = await repository.list(widget.ownerId);
      if (!mounted || version != refreshVersion) return;
      setState(() => pending = commands);
      String? failure;
      final sendable = commands
          .where(
            (p) =>
                p['kind'] == 'delete_batch' &&
                p['sync_status'] != 'retry_required',
          )
          .toList();
      if (sendable.isNotEmpty && widget.checkHandlingCapability != null) {
        try {
          await widget.checkHandlingCapability!();
        } catch (e) {
          failure = _handlingError(e);
          for (final command in sendable) {
            await repository.setRetry(
              widget.ownerId,
              command['operation_key'] as String,
              failure: failure,
            );
          }
          sendable.clear(); // No POST to an unadvertised route; keep the queue.
        }
      }
      for (final command in sendable) {
        try {
          await (widget.sendHandling ?? PocketBaseService.sendExpiryHandling)(
            widget.ownerId,
            command,
          );
          if (mounted && version == refreshVersion) {
            setState(
              () => batches.removeWhere((b) => b.id == command['batch']),
            );
          }
          await repository.cancel(
            widget.ownerId,
            command['operation_key'] as String,
          );
        } catch (e) {
          failure = _handlingError(e);
          await repository.setRetry(
            widget.ownerId,
            command['operation_key'] as String,
            failure: failure,
          );
        }
      }
      final remaining = await repository.list(widget.ownerId);
      if (!mounted || version != refreshVersion) return;
      setState(() {
        pending = remaining;
        syncError =
            failure ??
            remaining
                .map((p) => p['sync_error'])
                .whereType<String>()
                .firstOrNull;
      });
      final records =
          await (widget.loadBatches?.call() ??
              PocketBaseService.getExpiryBatches(includeClosed: true));
      await _clearConfirmedClosed(records);
      if (mounted && version == refreshVersion) {
        setState(() {
          batches = records.where((b) => !b.closed).toList()
            ..sort(
              (a, b) => (a.days ?? 0x7fffffff).compareTo(b.days ?? 0x7fffffff),
            );
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

  void _showSyncDetails() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Подробности за синхронизацията'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                [
                  if (error != null) 'Списък с партиди: $error',
                  if (syncError != null) 'Изпращане на заявки: $syncError',
                ].join('\n\n'),
              ),
              for (final command in pending) ...[
                Text('Партида: ${command['batch']}'),
                Wrap(
                  children: [
                    if (command['kind'] == 'delete_batch')
                      TextButton(
                        onPressed: acting || loading
                            ? null
                            : () {
                                Navigator.pop(context);
                                _retry(command);
                              },
                        child: const Text('Повтори'),
                      ),
                    TextButton(
                      onPressed: acting || loading
                          ? null
                          : () {
                              Navigator.pop(context);
                              _cancel(command);
                            },
                      child: const Text('Отмени локалната заявка'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Затвори'),
          ),
        ],
      ),
    );
  }

  Future<void> _handle(
    ExpiryBatch batch, {
    required bool replacingLegacy,
  }) async {
    if (acting || loading) return;
    setState(() => acting = true);
    try {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Премахни от списъка'),
          content: Text(
            '${batch.productName}\n'
            '${batch.barcode.isEmpty ? '' : 'Баркод: ${batch.barcode}\n'}'
            'Годност до ${batch.dateLabel}\n\n'
            'Тази партида ще бъде изтрита окончателно от PocketBase. Продуктът, другите партиди и движенията ще се запазят. Действието не може да бъде отменено от приложението.'
            '${replacingLegacy ? '\nТова заменя старата неизпратена проверка за същия запис.' : ''}',
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
      if (approved != true || !mounted) return;
      await repository.prepare(
        owner: widget.ownerId,
        batch: batch,
        kind: 'delete_batch',
        quantity: '0',
      );
      if (mounted) await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              pending.any((p) => p['batch'] == batch.id)
                  ? 'Не е потвърдено от PocketBase. Заявката е запазена за ръчен повторен опит.'
                  : 'Партидата е изтрита окончателно от PocketBase.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Заявката не е записана: $e')));
      }
    } finally {
      if (mounted) setState(() => acting = false);
    }
  }

  Future<void> _cancel(Map<String, dynamic> command) async {
    if (acting || loading) return;
    setState(() => acting = true);
    try {
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Отмени неизпратената заявка?'),
          content: const Text(
            'Ще се спре повторното изпращане от този телефон. Вече потвърден запис в PocketBase няма да бъде върнат.',
          ),
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
      if (yes != true || !mounted) return;
      await repository.cancel(
        widget.ownerId,
        command['operation_key'] as String,
      );
      if (mounted) await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = searchController.text.trim().toLowerCase();
    final visible =
        batches.where((batch) {
          final state = ExpiryState.of(batch);
          return (batch.productName.toLowerCase().contains(query) ||
                  batch.barcode.contains(query)) &&
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
                          if (widget.onAddBatch != null)
                            OutlinedButton.icon(
                              onPressed: widget.onAddBatch,
                              icon: const Icon(Icons.qr_code),
                              label: const Text('Добави срок по баркод'),
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
                                  TextButton(
                                    onPressed: _showSyncDetails,
                                    child: const Text(
                                      'Подробности за синхронизацията',
                                    ),
                                  ),
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
                          hintText: 'Име или баркод',
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
                      if (syncError != null || pending.isNotEmpty)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Има непотвърдени заявки'),
                          subtitle: const Text(
                            'Отворете подробностите за повторен опит или отмяна на локалната заявка.',
                          ),
                          trailing: IconButton(
                            tooltip: 'Подробности за синхронизацията',
                            icon: const Icon(Icons.info_outline),
                            onPressed: _showSyncDetails,
                          ),
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
                      actions: Wrap(
                        spacing: AppSpacing.small,
                        children: [
                          if (commands.isNotEmpty) ...[
                            const Text(
                              'Неизпратена проверка на този телефон. Не е отразена в PocketBase.',
                            ),
                            if (commands.first['kind'] == 'delete_batch')
                              TextButton(
                                onPressed: acting || loading
                                    ? null
                                    : () => _retry(commands.first),
                                child: const Text('Опитай синхронизация'),
                              )
                            else
                              const Text(
                                'Стара проверка: потвърдете обработването отново.',
                              ),
                            TextButton(
                              onPressed: acting || loading
                                  ? null
                                  : () => _cancel(commands.first),
                              child: const Text('Отмени неизпратената заявка'),
                            ),
                          ],
                          if (!commands.any((p) => p['kind'] == 'delete_batch'))
                            TextButton(
                              onPressed: acting || loading
                                  ? null
                                  : () => _handle(
                                      batch,
                                      replacingLegacy: commands.isNotEmpty,
                                    ),
                              child: const Text('Премахни от списъка'),
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
