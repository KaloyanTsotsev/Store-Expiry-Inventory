import 'dart:io';

import 'package:pocketbase/pocketbase.dart';

/// Read-only SDK probe. Deliberately anonymous; does not test employee access.
Future<void> main() async {
  final pb = PocketBase('http://192.168.1.200:8090');
  try {
    final records = await pb.collection('products').getFullList(sort: 'name');
    stdout.writeln(
      'Anonymous getFullList(sort: name): ${records.length} records',
    );
    stdout.writeln(
      'Employee authorization and create have NOT been tested by this probe.',
    );
  } on ClientException catch (error) {
    stderr.writeln('HTTP ${error.statusCode}; response=${error.response}');
    rethrow;
  }
}
