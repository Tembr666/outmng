import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/transfer_service.dart';
import '../theme.dart';
import '../widgets/device_tile.dart';

/// Экран передачи: две кнопки и история файлов.
class TransferScreen extends StatelessWidget {
  const TransferScreen({
    super.key,
    required this.device,
    required this.service,
  });

  final Device device;
  final TransferService service;

  Future<void> _send(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: false,
      dialogTitle: 'Выберите файлы',
    );
    if (result == null || result.files.isEmpty) return;
    final paths = result.files
        .map((file) => file.path)
        .whereType<String>()
        .toList(growable: false);
    if (paths.isEmpty) return;

    final summary = await service.sendFiles(device, paths);
    if (!context.mounted) return;
    final text = summary.allOk
        ? 'Отправлено: ${summary.sent}'
        : 'Отправлено ${summary.sent} из ${summary.total}'
              '${summary.errors.isEmpty ? '' : '\n${summary.errors.first}'}';
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _clearHistory(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Очистить историю?'),
        content: const Text(
          'Список отправленных и принятых файлов будет очищен только '
          'на этом устройстве. Сами файлы останутся на диске.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (confirmed == true) service.clearHistory();
  }

  void _showServerStatus(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ServerSheet(service: service),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              device.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '${device.type.label} · ${device.ip}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Icon(
              deviceTypeIcon(device.type),
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
              child: AnimatedBuilder(
                animation: service,
                builder: (context, _) {
                  final busy = service.isBusy;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: _ActionCard(
                              icon: Icons.upload_rounded,
                              label: 'Отправить',
                              primary: true,
                              onTap: busy ? null : () => _send(context),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _ActionCard(
                              icon: Icons.download_rounded,
                              label: 'Принять',
                              primary: false,
                              onTap: () => _showServerStatus(context),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (busy) ...<Widget>[
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  service.activeFileName ?? 'Передача…',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                                const SizedBox(height: 10),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: LinearProgressIndicator(
                                    value: service.progress,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                      Row(
                        children: <Widget>[
                          Text(
                            'Файлы',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          if (service.records.isNotEmpty)
                            IconButton(
                              tooltip: 'Очистить историю',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _clearHistory(context),
                              icon: const Icon(
                                Icons.delete_sweep_outlined,
                                size: 20,
                              ),
                            ),
                          Text(
                            '${service.records.length}',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: service.records.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Icon(
                                      Icons.folder_open_rounded,
                                      size: 34,
                                      color: scheme.onSurfaceVariant.withValues(
                                        alpha: 0.6,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      'Здесь появятся переданные файлы',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.separated(
                                padding: EdgeInsets.zero,
                                itemCount: service.records.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, index) {
                                  final record = service.records[index];
                                  return _RecordTile(record: record);
                                },
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.label,
    required this.primary,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = primary ? scheme.primary : scheme.surface;
    final foreground = primary ? scheme.onPrimary : scheme.onSurface;
    final disabled = onTap == null;

    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: Material(
        color: background,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          side: BorderSide(
            color: primary
                ? Colors.transparent
                : scheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 112,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(icon, size: 30, color: foreground),
                const SizedBox(height: 10),
                Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record});

  final TransferRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sent = record.direction == TransferDirection.sent;
    final time =
        '${record.time.hour.toString().padLeft(2, '0')}:'
        '${record.time.minute.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color:
                  (sent ? scheme.primaryContainer : scheme.secondaryContainer)
                      .withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              sent ? Icons.north_east_rounded : Icons.south_west_rounded,
              size: 19,
              color: sent
                  ? scheme.onPrimaryContainer
                  : scheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  record.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${record.sizeLabel} · ${record.peer} · $time',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            record.ok
                ? Icons.check_circle_rounded
                : Icons.error_outline_rounded,
            size: 19,
            color: record.ok ? const Color(0xFF34C759) : scheme.error,
          ),
        ],
      ),
    );
  }
}

class _ServerSheet extends StatefulWidget {
  const _ServerSheet({required this.service});

  final TransferService service;

  @override
  State<_ServerSheet> createState() => _ServerSheetState();
}

class _ServerSheetState extends State<_ServerSheet> {
  String? _folder;

  @override
  void initState() {
    super.initState();
    widget.service.downloadDirectoryPath().then((path) {
      if (mounted) setState(() => _folder = path);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: AnimatedBuilder(
          animation: widget.service,
          builder: (context, _) {
            final service = widget.service;
            final received = service.receivedRecords;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      service.isRunning
                          ? Icons.wifi_tethering_rounded
                          : Icons.wifi_tethering_off_rounded,
                      color: service.isRunning
                          ? const Color(0xFF34C759)
                          : scheme.error,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      service.isRunning ? 'Приём включён' : 'Приём выключен',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  service.isRunning
                      ? 'Отправьте файлы на ${service.endpoint}'
                      : 'Сервер не запущен',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                if (service.isBusy) ...<Widget>[
                  Text(
                    service.activeFileName ?? 'Получение файла…',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(value: service.progress),
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: <Widget>[
                    _InfoChip(
                      icon: Icons.south_west_rounded,
                      text: '${received.length} файлов',
                    ),
                    const SizedBox(width: 8),
                    _InfoChip(
                      icon: Icons.tag_rounded,
                      text: 'порт ${service.port}',
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (_folder != null)
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.folder_rounded,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _folder!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                if (!Platform.isAndroid) ...<Widget>[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => service.openDownloadFolder(),
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('Открыть папку'),
                  ),
                ],
                if (received.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 18),
                  Text(
                    'Принято',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: received.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _RecordTile(record: received[index]),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
