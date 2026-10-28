import 'dart:io';

import 'package:flutter/material.dart';

void showDocumentPhoto(BuildContext context, String path) => showDialog<void>(
  context: context,
  builder: (context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Документ'),
        leading: IconButton(
          tooltip: 'Затвори',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: InteractiveViewer(
        minScale: .5,
        maxScale: 8,
        child: Center(
          child: Image.file(
            File(path),
            errorBuilder: (_, _, _) => const Text('Снимката не е достъпна.'),
          ),
        ),
      ),
    ),
  ),
);
