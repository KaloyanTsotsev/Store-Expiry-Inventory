import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pocketbase/pocketbase.dart';

import 'ocr_service.dart';
import 'pocketbase_service.dart';

class ServerOcrEngine implements OcrEngine {
  const ServerOcrEngine({this.timeout = const Duration(seconds: 205)});
  final Duration timeout;
  @override
  Future<Map<String, dynamic>> recognize(String imagePath) async {
    final pb = PocketBaseService.pb;
    if (!pb.authStore.isValid ||
        pb.authStore.record?.collectionName != 'employees') {
      throw StateError('Сесията е изтекла. Влезте отново.');
    }
    final file = File(imagePath);
    if (await file.length() > 9 * 1024 * 1024) {
      throw const FormatException(
        'Снимката надхвърля 9 MiB. Изберете по-малка снимка.',
      );
    }
    try {
      return await pb
          .send<Map<String, dynamic>>(
            '/api/store/ocr/recognize',
            method: 'POST',
            body: {'image_base64': base64Encode(await file.readAsBytes())},
          )
          .timeout(timeout);
    } on TimeoutException {
      throw StateError(
        'OCR отне твърде дълго. Опитайте отново или въведете ръчно.',
      );
    } on ClientException catch (error) {
      final message = switch (error.statusCode) {
        401 => 'Сесията е изтекла. Влезте отново.',
        403 => 'Нямате право да обработвате документи.',
        400 || 415 => 'Файлът не е валидна JPEG/PNG снимка.',
        413 => 'Снимката е прекалено голяма (лимит 9 MiB).',
        429 => 'OCR услугата е заета. Изчакайте и опитайте отново.',
        504 => 'OCR обработката надхвърли времето за изчакване.',
        _ => 'PaddleOCR е недостъпен. Опитайте отново или въведете ръчно.',
      };
      throw StateError(message);
    }
  }
}
