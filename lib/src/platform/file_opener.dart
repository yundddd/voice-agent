/// Seam: hand a received file to the operating system's viewer — on
/// Android that is the package installer for an .apk (the self-update
/// loop's last mile) and whatever app claims the type for the rest.
/// A class, not a bare channel call, so VM tests swap in a recorder
/// instead of a platform.
library;

import 'package:flutter/services.dart';

abstract class FileOpener {
  Future<void> open(String path, {required String mime});
}

/// The production opener: 'voiceagent/files' OPEN (see MainActivity.kt:
/// FileProvider + ACTION_VIEW + a per-URI read grant). Where no handler
/// is installed (VM tests, a Linux dev run) the invoke throws
/// MissingPluginException and the bubble admits it honestly.
class ChannelFileOpener implements FileOpener {
  static const _channel = MethodChannel('voiceagent/files');

  @override
  Future<void> open(String path, {required String mime}) =>
      _channel.invokeMethod<void>('open', {'path': path, 'mime': mime});
}

/// The mime an open request claims. The installer only recognises
/// application/vnd.android.package-archive; anything else is guessed
/// from the extension, and '*/*' lets the system pick.
String mimeForFile(String name) {
  final ext = name.contains('.')
      ? name.split('.').last.toLowerCase()
      : '';
  return switch (ext) {
    'apk' => 'application/vnd.android.package-archive',
    'zip' => 'application/zip',
    'txt' || 'log' => 'text/plain',
    'json' => 'application/json',
    'pdf' => 'application/pdf',
    _ => '*/*',
  };
}
