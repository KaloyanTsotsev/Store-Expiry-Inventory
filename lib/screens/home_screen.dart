import 'package:flutter/material.dart';

import '../services/pocketbase_service.dart';
import '../theme/app_theme.dart';
import '../widgets/expiry_dashboard.dart';
import 'deliveries_screen.dart';
import 'login_screen.dart';
import 'products_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int section = 0;
  bool openingScanner = false;
  final dashboard = GlobalKey<ExpiryDashboardState>();
  Future<void> _scan() async {
    if (openingScanner) return;
    setState(() => openingScanner = true);
    try {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const DeliveriesScreen(startNew: true),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => openingScanner = false);
        dashboard.currentState?.refresh();
      }
    }
  }

  void _logout() {
    PocketBaseService.logout();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = PocketBaseService.pb.authStore.record;
    final name = [user?.data['name'], user?.data['username'], 'Служител']
        .map((value) => value?.toString().trim() ?? '')
        .firstWhere((v) => v.isNotEmpty);
    return Scaffold(
      bottomNavigationBar: NavigationBar(
        selectedIndex: section,
        onDestinationSelected: (index) => setState(() => section = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.space_dashboard_outlined),
            selectedIcon: Icon(Icons.space_dashboard),
            label: 'Начало',
          ),
          NavigationDestination(
            icon: Icon(Icons.document_scanner_outlined),
            selectedIcon: Icon(Icons.document_scanner),
            label: 'Доставки',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Продукти',
          ),
        ],
      ),
      body: switch (section) {
        1 => DeliveriesScreen(onFinalized: () => setState(() => section = 0)),
        2 => const ProductsScreen(),
        _ => Scaffold(
          appBar: AppBar(
            title: const Text('StoreFlow'),
            actions: [
              const ThemeMenu(),
              IconButton(
                tooltip: 'Изход',
                icon: const Icon(Icons.logout),
                onPressed: _logout,
              ),
            ],
          ),
          body: ExpiryDashboard(
            key: dashboard,
            ownerId: user?.id ?? '',
            employeeName: name,
            onScan: openingScanner ? null : _scan,
            onDrafts: () => setState(() => section = 1),
          ),
        ),
      },
    );
  }
}
