import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Lets the person choose a folder Kendra can write files into (backups).
/// Returns its path, or null if they cancel.
///
/// On Mac and Windows this is the system folder dialog, so USB drives and
/// network folders work. Android only lets an app write plain files inside its
/// own storage areas, so there the choice is between the tablet's storage and
/// an SD card or USB drive, when one is plugged in.
Future<String?> pickFolder(BuildContext context, {String confirmLabel = 'Use this folder'}) async {
  if (!Platform.isAndroid) return getDirectoryPath(confirmButtonText: confirmLabel);
  final dirs = await getExternalStorageDirectories() ?? const <Directory>[];
  if (!context.mounted) return null;
  if (dirs.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('No other storage found'),
        content: const Text('This tablet has no storage Kendra can save to besides its own folder.'),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
    return null;
  }
  return showDialog<String>(
    context: context,
    builder: (c) => SimpleDialog(
      title: const Text('Where should backups go?'),
      children: [
        for (final (i, d) in dirs.indexed)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, '${d.path}${Platform.pathSeparator}backups'),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(i == 0 ? Icons.tablet_android_outlined : Icons.sd_card_outlined),
              title: Text(i == 0 ? "Tablet's shared storage" : 'SD card or USB drive'),
              subtitle: Text(i == 0
                  ? 'Reachable from a computer over a USB cable. Removed if Kendra is uninstalled.'
                  : 'Can be taken out and kept somewhere safe. Removed if Kendra is uninstalled.'),
            ),
          ),
      ],
    ),
  );
}
