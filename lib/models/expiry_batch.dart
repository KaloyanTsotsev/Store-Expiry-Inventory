import 'package:pocketbase/pocketbase.dart';

import 'delivery_draft.dart';

enum ExpiryBucket { expired, today, week, month, later, unknown }

class ExpiryBatch {
  static const defaultWarningDays = 7;
  final String id, productName, lot, status;
  final DateTime? expiry;
  final int? days, revision;
  final int warningDays;
  final bool customWarning;
  final num? quantity;
  final String unit;
  ExpiryBatch({
    required this.id,
    required this.productName,
    required this.lot,
    required this.status,
    required this.expiry,
    required this.days,
    required this.revision,
    required this.warningDays,
    required this.customWarning,
    this.quantity,
    this.unit = '',
  });

  static DateTime? dateOnly(String value) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:$|[ T])')
        .firstMatch(value);
    if (match == null) return null;
    final y = int.parse(match[1]!),
        m = int.parse(match[2]!),
        d = int.parse(match[3]!);
    final date = DateTime.utc(y, m, d);
    return date.year == y && date.month == m && date.day == d ? date : null;
  }

  factory ExpiryBatch.fromRecord(RecordModel record, {required DateTime now}) {
    final product = record
        .get<List<RecordModel>>('expand.product', [])
        .firstOrNull;
    final expiry = dateOnly(record.data['expiry_date']?.toString() ?? '');
    final today = DateTime.utc(now.year, now.month, now.day);
    final warning = product?.data['expiry_warning_days'];
    final custom =
        warning is num &&
        warning.isFinite &&
        warning == warning.round() &&
        warning >= 0 &&
        warning <= 365;
    final productId = record.data['product']?.toString() ?? '';
    final name = product?.data['name']?.toString().trim() ?? '';
    final revision = record.data['revision'];
    final quantity = record.data['quantity'];
    return ExpiryBatch(
      id: record.id,
      productName: name.isNotEmpty
          ? name
          : productId.isEmpty
          ? 'Продукт без име'
          : 'Продукт $productId',
      lot: normalizeLotNumber(record.data['lot_number']?.toString()),
      status: record.data['status']?.toString().trim().toLowerCase() ?? '',
      expiry: expiry,
      days: expiry?.difference(today).inDays,
      revision:
          revision is num &&
              revision.isFinite &&
              revision >= 0 &&
              revision == revision.round()
          ? revision.toInt()
          : null,
      warningDays: custom ? warning.toInt() : defaultWarningDays,
      customWarning: custom,
      quantity: quantity is num && quantity.isFinite && quantity >= 0
          ? quantity
          : null,
      unit:
          (record.data['unit'] ?? product?.data['unit'])?.toString().trim() ??
          '',
    );
  }
  bool get closed => status == 'closed';
  ExpiryBucket get bucket {
    final d = days;
    if (d == null) return ExpiryBucket.unknown;
    if (d < 0) return ExpiryBucket.expired;
    if (d == 0) return ExpiryBucket.today;
    if (d <= 7) return ExpiryBucket.week;
    if (d <= 30) return ExpiryBucket.month;
    return ExpiryBucket.later;
  }

  bool get alert => days != null && days! <= warningDays;
  String get label => days == null
      ? 'Непотвърден срок — нужна е проверка'
      : days! < 0
      ? 'Изтекъл — провери и отстрани от продажба'
      : days! <= warningDays
      ? 'Наближава изтичане — прецени за намаление'
      : 'В срок';
  String get dateLabel => expiry == null
      ? 'Неизвестен'
      : '${expiry!.day.toString().padLeft(2, '0')}.${expiry!.month.toString().padLeft(2, '0')}.${expiry!.year}';
  String get daysLabel => days == null
      ? 'Няма валидна дата'
      : days! < 0
      ? 'Изтекъл преди ${-days!} дни'
      : days == 0
      ? 'Изтича днес'
      : 'Остават $days календарни дни';
}
