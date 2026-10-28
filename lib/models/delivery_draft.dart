import 'dart:convert';
import 'dart:math';

String newDraftId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
    '${Random.secure().nextInt(0x7fffffff).toRadixString(36)}';

DateTime? parseDocumentDate(String value) {
  final match = RegExp(r'^(\d{2})\.(\d{2})\.(\d{4})$').firstMatch(value.trim());
  if (match == null) return null;
  final day = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final year = int.parse(match[3]!);
  if (year < 2000 || year > 2100) return null;
  final date = DateTime(year, month, day);
  return date.day == day && date.month == month && date.year == year
      ? date
      : null;
}

double? parseQuantity(String text) {
  if (!RegExp(r'^\d+(?:[.,]\d+)?$').hasMatch(text.trim())) return null;
  final quantity = double.tryParse(text.trim().replaceAll(',', '.'));
  return quantity != null && quantity.isFinite ? quantity : null;
}

String normalizeLotNumber(String? value) {
  final lot = value?.trim() ?? '';
  return lot.isEmpty || lot == '1' || lot.toUpperCase() == 'N/A' ? 'N/A' : lot;
}

class OcrWord {
  final int? line;
  final String text;
  final double confidence, left, top, right, bottom;
  const OcrWord(
    this.text,
    this.confidence,
    this.left,
    this.top,
    this.right,
    this.bottom, {
    this.line,
  });
  double get x => (left + right) / 2;
  double get y => (top + bottom) / 2;
  double get height => bottom - top;
  factory OcrWord.fromJson(Map<String, dynamic> json) => OcrWord(
    json['text'] as String,
    (json['confidence'] as num).toDouble(),
    (json['left'] as num).toDouble(),
    (json['top'] as num).toDouble(),
    (json['right'] as num).toDouble(),
    (json['bottom'] as num).toDouble(),
    line: json['line'] as int?,
  );
  Map<String, dynamic> toJson() => {
    'text': text,
    'line': line,
    'confidence': confidence,
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };
}

class DraftItem {
  final String id;
  final String? _sourceRowId;
  String get sourceRowId => _sourceRowId ?? id;
  String supplierCode, name, ordered, unit, expiry, difference, received;
  String _lot;
  String get lot => _lot;
  set lot(String value) => _lot = normalizeLotNumber(value);
  String? productId;
  bool checked;
  bool proposedNewProduct;
  bool catalogOnFinalize;
  String barcode, matchReason;
  bool productSelectionConfirmed;
  bool requiresCatalogIdentity;
  Map<String, dynamic>? catalogRequest;
  final Map<String, String> original;
  final List<String> _uncertainFields;
  List<String> get uncertainFields => _uncertainFields
      .where((field) => field != 'lot' || lot != 'N/A')
      .toList(growable: false);
  DraftItem({
    String? id,
    String? sourceRowId,
    this.supplierCode = '',
    this.name = '',
    this.ordered = '',
    this.unit = '',
    this.expiry = '',
    String lot = '',
    this.difference = '',
    this.received = '',
    this.productId,
    this.checked = false,
    this.proposedNewProduct = false,
    this.catalogOnFinalize = false,
    this.barcode = '',
    this.matchReason = '',
    this.productSelectionConfirmed = false,
    this.requiresCatalogIdentity = false,
    this.catalogRequest,
    this.original = const {},
    List<String> uncertainFields = const [],
  }) : id = id ?? newDraftId(),
       _sourceRowId = sourceRowId ?? id,
       _lot = normalizeLotNumber(lot),
       _uncertainFields = List.of(uncertainFields);

  List<String> get validationErrors {
    final errors = <String>[];
    if (catalogOnFinalize && catalogRequest != null) {
      errors.add(
        'Има непотвърдена отделна каталожна заявка. Обновете каталога и проверете резултата преди групово приключване.',
      );
    }
    if (name.trim().isEmpty) errors.add('Липсва име на продукта.');
    final count = parseQuantity(received);
    if (count == null) {
      errors.add('Въведете физически приетото количество (0 или повече).');
    }
    if (count != null && count > 0) {
      if (requiresCatalogIdentity &&
          productId == null &&
          !(catalogOnFinalize &&
              proposedNewProduct &&
              RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/\-]{0,127}$')
                  .hasMatch(supplierCode.trim()))) {
        errors.add(
          'Липсва потвърдена връзка доставчик + код. Потвърдете новия продукт или разрешете конфликта с управител.',
        );
      }
      if (productId == null &&
          !proposedNewProduct &&
          !requiresCatalogIdentity) {
        errors.add('Изберете продукт от каталога или подгответе нов продукт.');
      }
      if (parseDocumentDate(expiry) == null) {
        errors.add('Невалиден срок. Използвайте ДД.ММ.ГГГГ; „1“ не е дата.');
      }
    }
    return errors;
  }

  static const visibleFields = {
    'supplierCode',
    'name',
    'ordered',
    'barcode',
    'unit',
    'expiry',
    'lot',
  };
  bool get unclear =>
      !checked &&
      (uncertainFields.any(visibleFields.contains) ||
          validationErrors.isNotEmpty);

  /// All inline edits invalidate the physical confirmation, including edits back
  /// to the original value. A prefilling quantity never confirms an item.
  void edit(String field, String value) {
    final previous = toJson()[field];
    if (previous == value) return;
    switch (field) {
      case 'supplierCode':
        supplierCode = value;
      case 'name':
        name = value;
      case 'ordered':
        ordered = value;
      case 'unit':
        unit = value;
      case 'received':
        received = value;
      case 'barcode':
        barcode = value;
      case 'expiry':
        expiry = value;
      case 'lot':
        lot = value;
      default:
        throw ArgumentError('Неподдържано поле: $field');
    }
    checked = false;
    if (requiresCatalogIdentity && field == 'supplierCode') {
      productSelectionConfirmed = false;
    }
    if ((field == 'name' || field == 'supplierCode' || field == 'barcode') &&
        !productSelectionConfirmed) {
      productId = null;
      proposedNewProduct = false;
      matchReason = '';
    }
  }

  factory DraftItem.fromJson(Map<String, dynamic> j) => DraftItem(
    id: j['id'] as String,
    sourceRowId: j['sourceRowId'] as String?,
    supplierCode: j['supplierCode'] as String? ?? '',
    name: j['name'] as String? ?? '',
    ordered: j['ordered'] as String? ?? '',
    unit: j['unit'] as String? ?? '',
    expiry: j['expiry'] as String? ?? '',
    lot: j['lot'] as String? ?? '',
    difference: j['difference'] as String? ?? '',
    received: j['received'] as String? ?? '',
    productId: j['productId'] as String?,
    checked: j['checked'] == true,
    proposedNewProduct: j['proposedNewProduct'] == true,
    catalogOnFinalize: j['catalogOnFinalize'] == true,
    barcode: j['barcode'] as String? ?? '',
    matchReason: j['matchReason'] as String? ?? '',
    productSelectionConfirmed: j['productSelectionConfirmed'] == true,
    requiresCatalogIdentity:
        j['requiresCatalogIdentity'] == true ||
        (j['original'] as Map? ?? {}).containsKey('paddle_product'),
    catalogRequest: j['catalogRequest'] is Map
        ? Map<String, dynamic>.from(j['catalogRequest'] as Map)
        : null,
    original: Map<String, String>.from(j['original'] as Map? ?? {}),
    uncertainFields: List<String>.from(j['uncertainFields'] as List? ?? []),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceRowId': sourceRowId,
    'supplierCode': supplierCode,
    'name': name,
    'ordered': ordered,
    'unit': unit,
    'expiry': expiry,
    'lot': lot,
    'difference': difference,
    'received': received,
    'productId': productId,
    'checked': checked,
    'proposedNewProduct': proposedNewProduct,
    'catalogOnFinalize': catalogOnFinalize,
    'barcode': barcode,
    'matchReason': matchReason,
    'productSelectionConfirmed': productSelectionConfirmed,
    'requiresCatalogIdentity': requiresCatalogIdentity,
    'catalogRequest': catalogRequest,
    'original': original,
    'uncertainFields': uncertainFields,
  };
}

/// A document observation, never a product identifier. Values stay untrimmed.
class PageBarcode {
  final String value;
  final String? type;
  final Map<String, dynamic> original;
  const PageBarcode({required this.value, this.type, this.original = const {}});
  factory PageBarcode.fromJson(Map<String, dynamic> json) => PageBarcode(
    value: json['value'] as String,
    type: json['type'] as String?,
    original: Map<String, dynamic>.from(json['original'] as Map? ?? {}),
  );
  Map<String, dynamic> toJson() => {
    'value': value,
    'type': type,
    'original': original,
  };
}

class DraftPage {
  final String id;
  final String imagePath;
  String text;
  List<OcrWord> words;
  List<DraftItem> items;
  List<PageBarcode> barcodes;
  List<Map<String, dynamic>> refinements;
  int width, height, elapsedMs;
  String? error;
  String layoutNote;
  bool recognized;
  final String imageHash;
  DraftPage({
    String? id,
    required this.imagePath,
    this.text = '',
    this.barcodes = const [],
    this.words = const [],
    this.refinements = const [],
    List<DraftItem>? items,
    this.width = 0,
    this.height = 0,
    this.elapsedMs = 0,
    this.error,
    this.layoutNote = '',
    this.recognized = false,
    this.imageHash = '',
  }) : id = id ?? newDraftId(),
       items = items ?? [];
  factory DraftPage.fromJson(Map<String, dynamic> j) => DraftPage(
    id: j['id'] as String,
    imagePath: j['imagePath'] as String,
    text: j['text'] as String? ?? '',
    barcodes: (j['barcodes'] as List? ?? [])
        .map((b) => PageBarcode.fromJson(Map<String, dynamic>.from(b as Map)))
        .toList(),
    refinements: (j['refinements'] as List? ?? [])
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList(),
    words: (j['words'] as List? ?? [])
        .map((w) => OcrWord.fromJson(Map<String, dynamic>.from(w as Map)))
        .toList(),
    items: (j['items'] as List? ?? [])
        .map((i) => DraftItem.fromJson(Map<String, dynamic>.from(i as Map)))
        .toList(),
    width: j['width'] as int? ?? 0,
    height: j['height'] as int? ?? 0,
    elapsedMs: j['elapsedMs'] as int? ?? 0,
    error: j['error'] as String?,
    layoutNote: j['layoutNote'] as String? ?? '',
    recognized: j['recognized'] == true,
    imageHash: j['imageHash'] as String? ?? '',
  );

  /// V2 already persists text inside delivery_pages.raw_ocr. Keep the exact
  /// response as a string alongside page-scoped evidence; no schema change.
  String get evidenceText => barcodes.isEmpty
      ? text
      : jsonEncode({
          'storeflow_page_evidence_version': 1,
          'page_id': id,
          'original_ocr_text': text,
          'barcodes': barcodes.map((b) => b.toJson()).toList(),
        });
  Map<String, dynamic> toJson() => {
    'id': id,
    'imagePath': imagePath,
    'barcodes': barcodes.map((b) => b.toJson()).toList(),
    'refinements': refinements,
    'text': text,
    'words': words.map((w) => w.toJson()).toList(),
    'items': items.map((i) => i.toJson()).toList(),
    'width': width,
    'height': height,
    'elapsedMs': elapsedMs,
    'error': error,
    'layoutNote': layoutNote,
    'recognized': recognized,
    'imageHash': imageHash,
  };
}

class DeliveryDraft {
  final String id, ownerId;
  String supplier, documentNumber, documentDate;
  List<DraftPage> pages;
  DateTime updatedAt;
  String status;
  String? serverId;
  int? serverRevision;
  Map<String, dynamic>? stagingRequest,
      finalizationRequest,
      finalizationReceipt;
  DeliveryDraft({
    String? id,
    required this.ownerId,
    this.supplier = '',
    this.documentNumber = '',
    this.documentDate = '',
    List<DraftPage>? pages,
    DateTime? updatedAt,
    this.status = 'draft',
    this.serverId,
    this.serverRevision,
    this.stagingRequest,
    this.finalizationRequest,
    this.finalizationReceipt,
  }) : id = id ?? newDraftId(),
       pages = pages ?? [],
       updatedAt = updatedAt ?? DateTime.now();
  Iterable<DraftItem> get items => pages.expand((p) => p.items);
  bool get allReviewed =>
      items.isNotEmpty &&
      items.every((i) => i.checked && i.validationErrors.isEmpty) &&
      pages.every((p) => p.recognized && p.error == null);
  int get checkedCount =>
      items.where((i) => i.checked && i.validationErrors.isEmpty).length;
  factory DeliveryDraft.fromJson(Map<String, dynamic> j) {
    if (j['version'] != 1) {
      throw const FormatException('Неподдържана версия на чернова.');
    }
    return DeliveryDraft(
      id: j['id'] as String,
      ownerId: j['ownerId'] as String,
      status: j['status'] as String? ?? 'draft',
      serverId: j['serverId'] as String?,
      serverRevision: j['serverRevision'] as int?,
      stagingRequest: j['stagingRequest'] == null
          ? null
          : Map<String, dynamic>.from(j['stagingRequest'] as Map),
      finalizationRequest: j['finalizationRequest'] == null
          ? null
          : Map<String, dynamic>.from(j['finalizationRequest'] as Map),
      finalizationReceipt: j['finalizationReceipt'] == null
          ? null
          : Map<String, dynamic>.from(j['finalizationReceipt'] as Map),
      supplier: j['supplier'] as String? ?? '',
      documentNumber: j['documentNumber'] as String? ?? '',
      documentDate: j['documentDate'] as String? ?? '',
      pages: (j['pages'] as List)
          .map((p) => DraftPage.fromJson(Map<String, dynamic>.from(p as Map)))
          .toList(),
      updatedAt: DateTime.parse(j['updatedAt'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'ownerId': ownerId,
    'status': status,
    'serverId': serverId,
    'serverRevision': serverRevision,
    'stagingRequest': stagingRequest,
    'finalizationRequest': finalizationRequest,
    'finalizationReceipt': finalizationReceipt,
    'supplier': supplier,
    'documentNumber': documentNumber,
    'documentDate': documentDate,
    'updatedAt': updatedAt.toIso8601String(),
    'pages': pages.map((p) => p.toJson()).toList(),
  };
}
