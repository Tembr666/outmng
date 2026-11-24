import 'package:flutter/material.dart';

import 'screens/device_list_screen.dart';
import 'services/settings_service.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();
  await settings.load();
  runApp(OutMngApp(settings: settings));
}

/// Корневое приложение OutMNG.
class OutMngApp extends StatefulWidget {
  const OutMngApp({super.key, required this.settings});

  final SettingsService settings;

  @override
  State<OutMngApp> createState() => _OutMngAppState();
}

class _OutMngAppState extends State<OutMngApp> {
  final ValueNotifier<ThemeMode> _themeMode = ValueNotifier<ThemeMode>(
    ThemeMode.dark,
  );

  @override
  void dispose() {
    _themeMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'OutMNG',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: mode,
          home: DeviceListScreen(
            themeMode: _themeMode,
            settings: widget.settings,
          ),
        );
      },
    );
  }
}
