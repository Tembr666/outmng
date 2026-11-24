import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/discovery_service.dart';
import '../services/settings_service.dart';
import '../services/transfer_service.dart';
import '../services/usb_service.dart';
import '../widgets/device_tile.dart';
import '../widgets/theme_toggle.dart';
import 'transfer_screen.dart';

/// Главный экран: пока он открыт — работают mDNS и HTTP-сервер.
class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({
    super.key,
    required this.themeMode,
    required this.settings,
  });

  final ValueNotifier<ThemeMode> themeMode;
  final SettingsService settings;

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  late final DiscoveryService _discovery;
  late final TransferService _transfer;
  late final StreamSubscription<List<Device>> _subscription;
  late String _deviceName;
  late final DeviceType _deviceType;
  List<Device> _devices = const <Device>[];
  final Set<String> _hidden = <String>{};
  bool _refreshing = false;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    _deviceName = widget.settings.ownName(_defaultDeviceName());
    _deviceType = currentDeviceType;
    _discovery = DiscoveryService();
    _transfer = TransferService();
    widget.settings.addListener(_onSettingsChanged);
    _subscription = _discovery.devices.listen((devices) {
      if (!mounted) return;
      setState(() => _devices = devices);
    });
    unawaited(_bootstrap());
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _bootstrap() async {
    await _transfer.startServer(
      deviceName: _deviceName,
      deviceType: _deviceType,
      deviceId: widget.settings.deviceId,
    );
    if (!mounted) return;
    await _discovery.start(
      deviceName: _deviceName,
      deviceType: _deviceType,
      port: _transfer.port,
      deviceId: widget.settings.deviceId,
    );
    if (!mounted) return;
    setState(() {
      _startupError = _discovery.lastError ?? _transfer.error;
    });
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    unawaited(_subscription.cancel());
    unawaited(_discovery.dispose());
    unawaited(_transfer.stopServer());
    _transfer.dispose();
    super.dispose();
  }

  static String _defaultDeviceName() {
    final host = Platform.localHostname.trim();
    if (host.isNotEmpty &&
        host.toLowerCase() != 'localhost' &&
        host != '127.0.0.1') {
      return host;
    }
    if (Platform.isAndroid) return 'Android';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return 'OutMNG';
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _hidden.clear();
    });
    await _discovery.restart();
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _startupError = _discovery.lastError ?? _transfer.error;
    });
  }

  void _openDevice(Device device) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TransferScreen(device: device, service: _transfer),
      ),
    );
  }

  Future<void> _openUsb() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _UsbSheet(),
    );
  }

  Future<String?> _promptName({
    required String title,
    required String initial,
    String? hint,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: hint ?? 'Имя устройства',
            counterText: '',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _renameSelf() async {
    final name = await _promptName(
      title: 'Имя этого устройства',
      initial: _deviceName,
      hint: 'Например: Ноутбук',
    );
    if (name == null || !mounted) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == _deviceName) return;

    setState(() => _refreshing = true);
    await widget.settings.setOwnName(trimmed);
    _deviceName = widget.settings.ownName(_defaultDeviceName());
    _transfer.updateDeviceName(_deviceName);
    await _discovery.stop();
    await _discovery.start(
      deviceName: _deviceName,
      deviceType: _deviceType,
      port: _transfer.port,
      deviceId: widget.settings.deviceId,
    );
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _startupError = _discovery.lastError ?? _transfer.error;
    });
  }

  Future<void> _renameDevice(Device device) async {
    final current = widget.settings.displayName(device);
    final name = await _promptName(
      title: 'Имя устройства',
      initial: current,
      hint: device.name,
    );
    if (name == null || !mounted) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == device.name) {
      await widget.settings.setAlias(device.id, null);
    } else {
      await widget.settings.setAlias(device.id, trimmed);
    }
  }

  void _deleteDevice(Device device) {
    setState(() => _hidden.add(device.id));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Устройство «${device.name}» скрыто'),
        action: SnackBarAction(
          label: 'Вернуть',
          onPressed: () {
            if (!mounted) return;
            setState(() => _hidden.remove(device.id));
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 700;

    final visible = <Device>[];
    final originals = <String, Device>{};
    for (final device in _devices) {
      if (_hidden.contains(device.id)) continue;
      originals[device.id] = device;
      final alias = widget.settings.displayName(device);
      visible.add(alias == device.name ? device : device.copyWith(name: alias));
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: wide ? 28 : 20,
        title: const Text('OutMNG'),
        actions: <Widget>[
          if (UsbService.isSupported)
            IconButton(
              tooltip: 'USB / MTP',
              onPressed: _openUsb,
              icon: const Icon(Icons.usb_rounded),
            ),
          ThemeToggle(mode: widget.themeMode),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Обновить',
            onPressed: _refreshing ? null : _refresh,
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
          SizedBox(width: wide ? 20 : 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                wide ? 28 : 18,
                4,
                wide ? 28 : 18,
                18,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _SelfCard(
                    name: _deviceName,
                    type: _deviceType,
                    transfer: _transfer,
                    onRename: _renameSelf,
                  ),
                  if (_startupError != null) ...<Widget>[
                    const SizedBox(height: 12),
                    _WarningBanner(text: _startupError!),
                  ],
                  const SizedBox(height: 22),
                  Row(
                    children: <Widget>[
                      Text(
                        'Рядом',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (visible.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${visible.length}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      const Spacer(),
                      if (visible.isEmpty && !_refreshing)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: visible.isEmpty
                        ? _EmptyState(
                            searching: !_refreshing,
                            hiddenCount: _hidden.length,
                          )
                        : ListView.separated(
                            padding: EdgeInsets.zero,
                            itemCount: visible.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final device = visible[index];
                              return DeviceTile(
                                device: device,
                                hasAlias: widget.settings.hasAlias(device.id),
                                onTap: () => _openDevice(device),
                                onRename: () => _renameDevice(
                                  originals[device.id] ?? device,
                                ),
                                onDelete: () => _deleteDevice(device),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 12),
                  _Footer(
                    endpoint: _transfer.endpoint,
                    serverRunning: _transfer.isRunning,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelfCard extends StatelessWidget {
  const _SelfCard({
    required this.name,
    required this.type,
    required this.transfer,
    required this.onRename,
  });

  final String name;
  final DeviceType type;
  final TransferService transfer;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AnimatedBuilder(
      animation: transfer,
      builder: (context, _) {
        final running = transfer.isRunning;
        return Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
            child: Row(
              children: <Widget>[
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    deviceTypeIcon(type),
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        running
                            ? '${transfer.endpoint} · виден в сети'
                            : 'Сервер не запущен',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Переименовать это устройство',
                  onPressed: onRename,
                  icon: const Icon(Icons.edit_rounded, size: 20),
                ),
                Container(
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: running ? const Color(0xFF34C759) : scheme.error,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.searching, this.hiddenCount = 0});

  final bool searching;
  final int hiddenCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primaryContainer.withValues(alpha: 0.5),
            ),
            child: Icon(
              Icons.wifi_tethering_rounded,
              size: 34,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            searching ? 'Ищем устройства…' : 'Пока никого нет',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hiddenCount > 0
                ? 'Скрыто устройств: $hiddenCount\nНажмите ↻, чтобы вернуть'
                : 'Оба устройства должны быть\nв одной Wi-Fi сети',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.endpoint, required this.serverRunning});

  final String endpoint;
  final bool serverRunning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(
          Icons.lock_outline_rounded,
          size: 13,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            serverRunning
                ? 'Работает только пока окно открыто · $endpoint'
                : 'Приложение закрыто — сервер остановлен',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),
        ),
      ],
    );
  }
}

class _UsbSheet extends StatefulWidget {
  const _UsbSheet();

  @override
  State<_UsbSheet> createState() => _UsbSheetState();
}

class _UsbSheetState extends State<_UsbSheet> {
  static const UsbService _usb = UsbService();

  List<UsbDevice> _devices = const <UsbDevice>[];
  bool _loading = true;
  String? _error;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final devices = await _usb.listDevices();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _loading = false;
    });
  }

  Future<void> _import(UsbDevice device) async {
    setState(() {
      _importing = true;
      _error = null;
    });
    final result = await _usb.importFiles(context, device);
    if (!mounted) return;
    setState(() {
      _importing = false;
      _error = result.error;
    });
    if (result.cancelled) return;
    if (result.files > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Импортировано файлов: ${result.files}\n${result.directory}',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.usb_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Text(
                  'USB / MTP',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Обновить',
                  onPressed: _importing ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              Platform.isWindows
                  ? 'Подключите телефон кабелем и разрешите доступ к файлам.'
                  : 'Подключите телефон кабелем и разрешите доступ к файлам. '
                        'Устройство появится в системе как MTP.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (_importing || _loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: <Widget>[
                    Icon(
                      Icons.usb_off_rounded,
                      size: 36,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'USB-устройства не найдены',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _devices.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final device = _devices[index];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.phone_android_rounded),
                        title: Text(device.name),
                        subtitle: Text(
                          Platform.isLinux
                              ? 'MTP · импорт в Загрузки/OutMNG'
                              : 'MTP',
                        ),
                        trailing: const Icon(Icons.download_rounded),
                        onTap: () => _import(device),
                      ),
                    );
                  },
                ),
              ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
