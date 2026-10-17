import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/speech/kokoro_voices.dart';

void main() {
  group('kokoro v1.0 speaker roster', () {
    test('table covers the shipped 54 voices, af_heart at sid 3', () {
      expect(kokoroSpeakerNames, hasLength(54));
      expect(kokoroSpeakerNames[3], 'af_heart'); // the sid the docs map
      expect(kokoroSpeakerNames[53], 'em_santa'); // the pack-appended one
    });

    test('names decode to language + gender; English sorts first', () {
      final roster = kokoroRoster(54);
      expect(roster[3].description, 'American English · female');
      expect(roster[16].description, 'American English · male');
      expect(roster[21].description, 'British English · female');
      expect(roster[45].description, 'Chinese · female');
      expect(roster[53].description, 'Spanish · male'); // README over prefix
      // The English block (sids 0..27) precedes every other style.
      expect(
        roster
            .where((s) => !s.english)
            .map((s) => s.order)
            .reduce((a, b) => a < b ? a : b),
        greaterThan(
          roster
              .where((s) => s.english)
              .map((s) => s.order)
              .reduce((a, b) => a > b ? a : b),
        ),
      );
    });

    test('a pack with more voices than the table still lists them', () {
      final roster = kokoroRoster(56);
      expect(roster[55].name, 'Speaker 56');
      expect(roster[55].description, contains('unknown style'));
    });

    test('bench-name helper survives junk sids', () {
      expect(kokoroSpeakerName(0, numSpeakers: 54), 'af_alloy');
      expect(kokoroSpeakerName(-1, numSpeakers: 54), 'current voice');
      expect(kokoroSpeakerName(99, numSpeakers: 54), 'current voice');
    });
  });
}
