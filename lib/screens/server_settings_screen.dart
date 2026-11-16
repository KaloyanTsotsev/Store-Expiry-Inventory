
import 'package:flutter/material.dart';

import '../services/pocketbase_service.dart';

class ServerSettingsScreen extends StatefulWidget {
  const ServerSettingsScreen({super.key});

  @override
  State<ServerSettingsScreen> createState() =>
      _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  late final TextEditingController ipController;

  bool isSaving = false;
  String? errorMessage;
  String? successMessage;

  @override
  void initState() {
    super.initState();

    final currentUrl = Uri.parse(PocketBaseService.pb.baseURL);
    ipController = TextEditingController(text: currentUrl.host);
  }

  Future<void> saveIp() async {
    if (isSaving) return;

    setState(() {
      isSaving = true;
      errorMessage = null;
      successMessage = null;
    });

    try {
      await PocketBaseService.saveServerIp(ipController.text);

      if (!mounted) return;

      setState(() {
        successMessage = 'Връзката е успешна. IP адресът е запазен.';
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        errorMessage = 'Неуспешна проверка или запис: $error';
      });
    } finally {
      if (mounted) {
        setState(() => isSaving = false);
      }
    }
  }

  @override
  void dispose() {
    ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки на сървъра'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Текущ сървър',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(PocketBaseService.pb.baseURL),
              const SizedBox(height: 32),
              TextField(
                controller: ipController,
                enabled: !isSaving,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'IP адрес на сървъра',
                  hintText: '192.168.100.46',
                  prefixIcon: Icon(Icons.dns_outlined),
                  border: OutlineInputBorder(),
                  helperText: 'Портът е 8090',
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: isSaving ? null : saveIp,
                icon: isSaving
                    ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                )
                    : const Icon(Icons.save_outlined),
                label: Text(
                  isSaving
                      ? 'Проверка на връзката...'
                      : 'Провери и запази',
                ),
              ),
              if (successMessage != null) ...[
                const SizedBox(height: 20),
                Text(
                  successMessage!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
              if (errorMessage != null) ...[
                const SizedBox(height: 20),
                Text(
                  errorMessage!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
