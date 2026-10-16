import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/app_events.dart';

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('applog');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  AppEventJournal journal({int? capacity}) =>
      AppEventJournal(dir: dir.path, ringCapacity: capacity ?? 240);

  group('ring + watermark', () {
    test('keeps newest-N and a monotonic sequence', () async {
      final j = journal(capacity: 5);
      for (var i = 0; i < 8; i++) {
        await j.log('event $i');
      }
      expect(j.seq, 8);
      final evs = j.eventsAfter(0);
      expect(evs.length, 5); // ring cap: the 5 newest
      expect(evs.first['msg'], 'event 3');
      expect(evs.last['msg'], 'event 7');
      expect(evs.every((e) => (e['t'] as int) > 0), isTrue);
    });

    test('eventsAfter is an incremental tail by watermark', () async {
      final j = journal();
      await j.log('one');
      await j.log('two');
      final tail = j.eventsAfter(1);
      expect(tail.map((e) => e['msg']).toList(), ['two']);
      expect(j.eventsAfter(99), isEmpty);
    });

    test('envelope carries the watermark, floor and live flags', () async {
      final j = journal();
      await j.log('x');
      final env = j.envelope(0, {'phase': 'idle'});
      expect(env['ok'], true);
      expect(env['seq'], 1);
      expect(env['floor'], 1);
      expect((env['events'] as List).length, 1);
      expect(env['flags'], {'phase': 'idle'});
    });
  });

  group('disk mirror (the process-death witness)', () {
    test('survives a restart and resumes the sequence', () async {
      final j = journal();
      await j.log('before the kill');
      final k = journal();
      await k.load();
      expect(k.seq, 1);
      await k.log('after the restart');
      final evs = k.eventsAfter(0);
      expect(evs.map((e) => e['msg']).toList(), [
        'before the kill',
        'after the restart',
      ]);
      // Seq is monotonic ACROSS process deaths: a bridge watermark
      // learned pre-kill still filters correctly post-restart.
      expect(k.eventsAfter(1).single['msg'], 'after the restart');
    });

    test('truncated last line (killed mid-append) is skipped, not fatal',
        () async {
      final j = journal();
      await j.log('fine');
      await File('${dir.path}/app_events.jsonl').writeAsString(
        '{"seq":2,"t":123,"ms',
        mode: FileMode.append,
      );
      final k = journal();
      await k.load();
      expect(k.eventsAfter(0).single['msg'], 'fine');
      await k.log('still logging');
      // The torn line is invisible to the counter too (never parsed, so
      // never counted): its seq is simply reused by the next event. The
      // one lost pre-kill event is the whole damage — a bridge watermark
      // never saw it either, so filtering stays consistent.
      expect(k.seq, 2);
    });

    test('mirror stays bounded across many appends', () async {
      final j = journal(capacity: 8);
      for (var i = 0; i < 300; i++) {
        await j.log('spam $i');
      }
      final lines = await File('${dir.path}/app_events.jsonl').readAsLines();
      expect(lines.length, lessThanOrEqualTo(8 + 64)); // ring + one rewrite gap
      final k = journal(capacity: 8);
      await k.load();
      expect(k.seq, 300); // watermark intact even as the file rolled
      expect(k.eventsAfter(0).length, lessThanOrEqualTo(8));
    });
  });

  group('HTTP endpoint (what the bridge dials)', () {
    test('serves envelopes, honours since, rejects wrong tokens', () async {
      final j = journal();
      await j.log('first');
      final port = await j.serve(
        preferredPort: 0, // ephemeral: CI-safe
        tokenProvider: () => 'sekret',
        flagsProvider: () => {'phase': 'idle', 'busy': false},
      );
      addTearDown(j.stop);
      expect(port, greaterThan(0));
      final client = HttpClient();
      Future<Map> get(String path) async {
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
        final res = await req.close();
        final body = await res.transform(utf8.decoder).join();
        return {'status': res.statusCode, 'body': jsonDecode(body)};
      }

      final r = await get('/applog?token=sekret&since=0');
      expect(r['status'], 200);
      final env = r['body'] as Map;
      expect(env['seq'], 1);
      expect((env['events'] as List).single['msg'], 'first');
      expect(env['flags'], {'phase': 'idle', 'busy': false});

      final empty = await get('/applog?token=sekret&since=1');
      expect((empty['body'] as Map)['events'], isEmpty);

      final bad = await get('/applog?token=nope&since=0');
      expect(bad['status'], 401);

      final late = await get('/applog?token=sekret&since=0&x=1');
      await j.log('second');
      final r2 = await get('/applog?token=sekret&since=1');
      expect((r2['body'] as Map)['events'].single['msg'], 'second');
      expect(late['status'], 200);
      client.close();
    });
  });
}
