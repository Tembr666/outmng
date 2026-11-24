import 'package:flutter/material.dart';

/// Кнопка переключения светлой/тёмной темы.
class ThemeToggle extends StatelessWidget {
  const ThemeToggle({super.key, required this.mode});

  final ValueNotifier<ThemeMode> mode;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: mode,
      builder: (context, value, _) {
        final isDark =
            value == ThemeMode.dark ||
            (value == ThemeMode.system &&
                Theme.of(context).brightness == Brightness.dark);
        return IconButton(
          tooltip: isDark ? 'Светлая тема' : 'Тёмная тема',
          icon: Icon(
            isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
          ),
          onPressed: () {
            mode.value = isDark ? ThemeMode.light : ThemeMode.dark;
          },
        );
      },
    );
  }
}
