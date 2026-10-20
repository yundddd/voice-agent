// The file bubble's tap-to-open: an APK tap fetches once and hands the
// bytes to the platform opener (the installer); a saved bubble's tap
// goes straight to the open without re-paying the download; a failed
// open lands on the bubble, never silently.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/assistant.dart';
import 'package:voice_agent/src/common/sinks.dart';
import 'package:voice_agent/src/platform/audio_output.dart';

import 'support/fakes.dart';

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Directory dir;
  late FakeHarness harness;
  late FakeOpener opener;
  late VoiceAssistant a;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('received');
    harness = FakeHarness();
    opener = FakeOpener();
    a = VoiceAssistant(
      worker: FakeSpeechEngine(),
      micSource: FakeMic(),
      audioOutput: FakeAudioOutput(),
      gatewayFactory: (_, _) => harness,
      opener: opener,
      receivedDir: () async => dir.path,
      scheduler: FakeScheduler(DateTime(2026, 1, 1, 12)),
      clock: () => DateTime(2026, 1, 1, 12),
    );
    await a.setBridge(url: 'http://bridge.test:8732', token: 'tok');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'one tap on an APK bubble: fetch, stamp saved, hand to installer',
    () async {
      harness.downloadBytes = [0x50, 0x4b, 3, 4];
      final e = ChatEntry.file(
        'app-release.apk',
        'dist/app-release.apk',
        4,
        createdMs: 1,
      );
      await a.fetchChatFile(e);
      await settle();
      expect(harness.downloadPaths, ['dist/app-release.apk']);
      expect(e.savedMs, greaterThan(0));
      expect(e.savedPath, '${dir.path}/app-release.apk');
      expect(File(e.savedPath).readAsBytesSync(), [0x50, 0x4b, 3, 4]);
      expect(opener.opened, [
        (
          '${dir.path}/app-release.apk',
          'application/vnd.android.package-archive',
        ),
      ], reason: 'apk mime — the package installer is what answers');
      expect(e.openError, isNull);
    },
  );

  test('a saved bubble taps to OPEN without re-downloading', () async {
    final onDisk = File('${dir.path}/report.pdf')..writeAsBytesSync([1, 2]);
    final e = ChatEntry.file('report.pdf', 'out/report.pdf', 2, createdMs: 1)
      ..savedMs = 5
      ..savedPath = onDisk.path;
    await a.fetchChatFile(e);
    await settle();
    expect(
      harness.downloadPaths,
      isEmpty,
      reason: 'the bytes are already here — no re-fetch',
    );
    expect(opener.opened, [(onDisk.path, 'application/pdf')]);
  });

  test('a failed open says so on the bubble, never silently', () async {
    opener.throwOnOpen = StateError('no viewer');
    final e = ChatEntry.file('thing.txt', 'out/thing.txt', 1, createdMs: 1);
    await a.fetchChatFile(e);
    await settle();
    expect(e.savedMs, greaterThan(0), reason: 'the download still landed');
    expect(e.openError, contains('no viewer'));
  });

  test(
    'download failure keeps the tap alive (no saved stamp, no open)',
    () async {
      harness.downloadOk = false;
      final e = ChatEntry.file('app.apk', 'dist/app.apk', 9, createdMs: 1);
      await a.fetchChatFile(e);
      await settle();
      expect(e.savedMs, 0);
      expect(opener.opened, isEmpty);
      expect(e.downloading, isFalse, reason: 'ready for the next tap');
    },
  );
}
