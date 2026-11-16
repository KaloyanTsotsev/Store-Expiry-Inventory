
import 'package:flutter/material.dart';

import 'screens/login_screen.dart';
import 'services/pocketbase_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await ThemeController.instance.load();
  } catch (error) {
    debugPrint('Theme preferences could not be loaded: $error');
  }

  try {
    await PocketBaseService.initialize();
  } catch (error) {
    debugPrint('PocketBase settings could not be loaded: $error');
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance,
      builder: (context, mode, _) => MaterialApp(
        title: 'StoreFlow',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(Brightness.light),
        darkTheme: AppTheme.build(Brightness.dark),
        themeMode: mode,
        home: const LoginScreen(),
      ),
    );
  }
}
