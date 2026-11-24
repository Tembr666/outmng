import 'package:flutter/material.dart';

import '../models/device.dart';
import '../theme.dart';

/// Иконка для типа устройства.
IconData deviceTypeIcon(DeviceType type) => switch (type) {
  DeviceType.android => Icons.phone_android_rounded,
  DeviceType.windows => Icons.desktop_windows_rounded,
  DeviceType.linux => Icons.computer_rounded,
  DeviceType.unknown => Icons.devices_other_rounded,
};

/// Строка списка найденных устройств.
class DeviceTile extends StatelessWidget {
  const DeviceTile({
    super.key,
    required this.device,
    this.onTap,
    this.onRename,
    this.onDelete,
    this.hasAlias = false,
  });

  final Device device;
  final VoidCallback? onTap;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final bool hasAlias;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasMenu = onRename != null || onDelete != null;

    return Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: <Widget>[
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  deviceTypeIcon(device.type),
                  size: 24,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            device.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (hasAlias) ...<Widget>[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.edit_rounded,
                            size: 12,
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.7,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${device.type.label} · ${device.ip}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (hasMenu)
                PopupMenuButton<String>(
                  tooltip: 'Действия',
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  onSelected: (value) {
                    if (value == 'rename') onRename?.call();
                    if (value == 'delete') onDelete?.call();
                  },
                  itemBuilder: (context) => <PopupMenuEntry<String>>[
                    if (onRename != null)
                      const PopupMenuItem<String>(
                        value: 'rename',
                        child: Row(
                          children: <Widget>[
                            Icon(Icons.edit_rounded, size: 18),
                            SizedBox(width: 10),
                            Text('Переименовать'),
                          ],
                        ),
                      ),
                    if (onDelete != null)
                      const PopupMenuItem<String>(
                        value: 'delete',
                        child: Row(
                          children: <Widget>[
                            Icon(Icons.delete_outline_rounded, size: 18),
                            SizedBox(width: 10),
                            Text('Удалить'),
                          ],
                        ),
                      ),
                  ],
                )
              else
                Icon(
                  Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
