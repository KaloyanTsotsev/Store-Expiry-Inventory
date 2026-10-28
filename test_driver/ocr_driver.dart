import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    writeResponseOnFailure: true,
    onScreenshot: (name, bytes, [args]) async {
      final folder = await Directory('build/screenshots')
          .create(recursive: true);
      await File('${folder.path}/$name.png').writeAsBytes(bytes);
      return true;
    },
    responseDataCallback: (data) async {
      final folder = await Directory('build/screenshots')
          .create(recursive: true);
      for (final preview in data?['previews'] as List? ?? []) {
        await File('${folder.path}/${preview['name']}.png')
            .writeAsBytes(List<int>.from(preview['bytes'] as List));
      }
      await Directory('build/ocr_benchmark').create(recursive: true);
      await File('build/ocr_benchmark/device_report.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(data?['ocr'] ?? []),
      );
    },
  );
}
