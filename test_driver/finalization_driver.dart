import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    writeResponseOnFailure: true,
    responseDataCallback: (data) async {
      final folder = await Directory('build/finalization_benchmark')
          .create(recursive: true);
      await File(
        '${folder.path}/device_report.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(data ?? {}));
    },
  );
}
