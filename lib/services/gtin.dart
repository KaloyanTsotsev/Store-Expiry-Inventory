/// Validates GTIN-8/12/13/14 check digits. Never repairs OCR digits.
String? gtinKey(String value) {
  final text = value.trim();
  if (!RegExp(r'^(?:\d{8}|\d{12}|\d{13}|\d{14})$').hasMatch(text)) return null;
  var sum = 0, weight = 3;
  for (var i = text.length - 2; i >= 0; i--, weight = 4 - weight) {
    sum += int.parse(text[i]) * weight;
  }
  return (10 - sum % 10) % 10 == int.parse(text[text.length - 1])
      ? text.padLeft(14, '0')
      : null;
}
