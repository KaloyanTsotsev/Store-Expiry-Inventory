import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController({
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
  }) : _read = read ?? _readSaved,
       _write = write ?? _writeSaved,
       super(ThemeMode.dark);
  static final instance = ThemeController();
  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  static Future<String?> _readSaved() =>
      SharedPreferencesAsync().getString('theme_mode');
  static Future<void> _writeSaved(String value) =>
      SharedPreferencesAsync().setString('theme_mode', value);
  Future<void> load() async {
    final saved = await _read();
    value =
        ThemeMode.values.where((v) => v.name == saved).firstOrNull ??
        ThemeMode.dark;
  }

  Future<void> select(ThemeMode mode) async {
    await _write(mode.name);
    value = mode;
  }
}

class AppTheme {
  static const emerald = Color(0xFF119C81);
  static ThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors =
        ColorScheme.fromSeed(
          seedColor: emerald,
          brightness: brightness,
        ).copyWith(
          primary: dark ? const Color(0xFF54D6B8) : const Color(0xFF007960),
          onPrimary: dark ? const Color(0xFF00382C) : Colors.white,
          surface: dark ? const Color(0xFF233244) : Colors.white,
          onSurface: dark ? const Color(0xFFF1F5F8) : const Color(0xFF111C29),
          onSurfaceVariant: dark
              ? const Color(0xFFB8C8D9)
              : const Color(0xFF4B6073),
          outlineVariant: dark
              ? const Color(0xFF415268)
              : const Color(0xFFCDD9E1),
          error: dark ? const Color(0xFFFFB3B8) : const Color(0xFFB42335),
        );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: dark
          ? const Color(0xFF111C29)
          : const Color(0xFFE9F0F3),
      appBarTheme: AppBarTheme(
        systemOverlayStyle: dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        backgroundColor: dark
            ? const Color(0xFF111C29)
            : const Color(0xFFE9F0F3),
        foregroundColor: colors.onSurface,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 6),
        color: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colors.surface,
        selectedColor: dark ? const Color(0xFF153E38) : const Color(0xFFD9F2E9),
        checkmarkColor: colors.primary,
        side: BorderSide(color: colors.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surface,
        indicatorColor: colors.primaryContainer,
      ),
    );
  }
}

class ThemeMenu extends StatelessWidget {
  const ThemeMenu({super.key});
  @override
  Widget build(BuildContext context) => PopupMenuButton<ThemeMode>(
    tooltip: 'Тема',
    icon: const Icon(Icons.contrast),
    initialValue: ThemeController.instance.value,
    onSelected: (mode) async {
      try {
        await ThemeController.instance.select(mode);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Темата не беше запазена. Опитайте отново.'),
            ),
          );
        }
      }
    },
    itemBuilder: (_) => [
      for (final entry in {
        ThemeMode.system: 'Системна',
        ThemeMode.light: 'Светла',
        ThemeMode.dark: 'Тъмна',
      }.entries)
        CheckedPopupMenuItem(
          value: entry.key,
          checked: ThemeController.instance.value == entry.key,
          child: Text(entry.value),
        ),
    ],
  );
}
