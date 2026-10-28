import 'package:flutter/material.dart';

import '../models/expiry_batch.dart';
import '../theme/app_spacing.dart';

enum ExpiryState {
  expired('Просрочени', 'Изтекъл срок', Icons.error_outline),
  soon('Скоро изтичащи', 'Изтича скоро', Icons.schedule_outlined),
  healthy('В срок', 'В срок', Icons.check_circle_outline),
  unknown('Без дата', 'Срок за проверка', Icons.help_outline);

  const ExpiryState(this.summary, this.label, this.icon);
  final String summary, label;
  final IconData icon;

  static ExpiryState of(ExpiryBatch batch) => batch.days == null
      ? unknown
      : batch.days! < 0
      ? expired
      : batch.alert
      ? soon
      : healthy;

  Color foreground(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (this) {
      expired => dark ? const Color(0xFFFFADB3) : const Color(0xFFAD2035),
      soon => dark ? const Color(0xFFFFC078) : const Color(0xFF965000),
      healthy => dark ? const Color(0xFF68DFBA) : const Color(0xFF00694F),
      unknown => Theme.of(context).colorScheme.onSurfaceVariant,
    };
  }

  Color background(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (this) {
      expired => dark ? const Color(0xFF472832) : const Color(0xFFFFEDEF),
      soon => dark ? const Color(0xFF403127) : const Color(0xFFFFF1DE),
      healthy => dark ? const Color(0xFF153E38) : const Color(0xFFE3F5ED),
      unknown => Theme.of(context).colorScheme.surfaceContainerHighest,
    };
  }
}

class ExpirySummary extends StatelessWidget {
  const ExpirySummary({super.key, required this.batches, required this.loaded});
  final List<ExpiryBatch> batches;
  final bool loaded;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      for (final state in [
        ExpiryState.expired,
        ExpiryState.soon,
        ExpiryState.healthy,
      ])
        Semantics(
          label:
              '${state.summary}: ${loaded ? batches.where((b) => ExpiryState.of(b) == state).length : 'не са заредени'} партиди',
          excludeSemantics: true,
          child: Container(
            key: ValueKey('summary-${state.name}'),
            decoration: BoxDecoration(
              color: state.background(context),
              borderRadius: BorderRadius.circular(AppSpacing.radius),
            ),
            padding: const EdgeInsets.all(AppSpacing.medium),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(state.icon, color: state.foreground(context), size: 22),
                const SizedBox(height: AppSpacing.small),
                Text(
                  loaded
                      ? '${batches.where((b) => ExpiryState.of(b) == state).length}'
                      : '—',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: state.foreground(context),
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  state.summary,
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: state.foreground(context)),
                ),
              ],
            ),
          ),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (MediaQuery.textScalerOf(context).scale(14) > 20 ||
            constraints.maxWidth < 280) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.small),
                tiles[i],
              ],
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(width: AppSpacing.small),
                Expanded(child: tiles[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

class ExpiryBatchCard extends StatelessWidget {
  const ExpiryBatchCard({
    super.key,
    required this.batch,
    required this.actions,
  });
  final ExpiryBatch batch;
  final Widget actions;

  String get quantityLabel {
    final value = batch.quantity;
    if (value == null) return 'Няма данни';
    final number = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toString();
    return '$number${batch.unit.isEmpty ? '' : ' ${batch.unit}'}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final state = ExpiryState.of(batch);
    final foreground = state.foreground(context);
    final dayCount = batch.days;
    final daysText = dayCount == null
        ? '—'
        : dayCount == 0
        ? 'Днес'
        : '${dayCount.abs()}';
    final daysCaption = dayCount == null
        ? 'Няма дата'
        : dayCount == 0
        ? 'Изтича срокът'
        : dayCount < 0
        ? (dayCount == -1 ? 'ден след срока' : 'дни след срока')
        : (dayCount == 1 ? 'ден остава' : 'дни остават');
    final date = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Годност до',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          batch.dateLabel,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
    final indicator = Semantics(
      label: batch.daysLabel,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minWidth: 104),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.large,
          vertical: AppSpacing.medium,
        ),
        decoration: BoxDecoration(
          color: state.background(context),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              daysText,
              style: theme.textTheme.headlineMedium?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              daysCaption,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium?.copyWith(color: foreground),
            ),
          ],
        ),
      ),
    );
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.large),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              batch.productName,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
            ),
            const SizedBox(height: AppSpacing.small),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(state.icon, size: 18, color: foreground),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    dayCount == 0 ? 'Изтича днес' : state.label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.large),
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 290 ||
                    MediaQuery.textScalerOf(context).scale(14) > 20) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      date,
                      const SizedBox(height: AppSpacing.medium),
                      indicator,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: date),
                    const SizedBox(width: AppSpacing.medium),
                    Flexible(child: indicator),
                  ],
                );
              },
            ),
            const SizedBox(height: AppSpacing.large),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.medium),
            LayoutBuilder(
              builder: (context, constraints) => Wrap(
                spacing: AppSpacing.large,
                runSpacing: AppSpacing.medium,
                children: [
                  for (final entry in {
                    'Количество от доставка': quantityLabel,
                    'Партида': batch.lot.trim().isEmpty ? 'N/A' : batch.lot,
                  }.entries)
                    SizedBox(
                      width:
                          constraints.maxWidth < 290 ||
                              MediaQuery.textScalerOf(context).scale(14) > 20
                          ? constraints.maxWidth
                          : (constraints.maxWidth - AppSpacing.large) / 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.key,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.value,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (batch.customWarning) ...[
              const SizedBox(height: AppSpacing.small),
              Text(
                'Предупреждение за продукта: ${batch.warningDays} дни',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (batch.status.isEmpty || batch.status == 'needs_review') ...[
              const SizedBox(height: AppSpacing.medium),
              const Text('Нужна е физическа проверка на партидата.'),
            ],
            const SizedBox(height: AppSpacing.small),
            actions,
          ],
        ),
      ),
    );
  }
}
