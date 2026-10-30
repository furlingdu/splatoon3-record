import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/domain/models.dart';
import 'package:splatoon3record/match/filter.dart';

void main() {
  BattleMatch Match(String Kind, String Rule, {bool Salmon = false}) {
    return BattleMatch.FromMap(<String, dynamic>{
      'matchId': 'm',
      'kind': Kind,
      'rule': Rule,
      'isSalmon': Salmon,
      'startAt': 1,
      'endAt': 2,
      'duration': 1,
    });
  }

  test('Match filter maps modes to recording toggles', () {
    final Settings = RecordSettings(RecordWork: true, RecordRanked: false, RecordTurf: false, RecordHighlight: true);
    expect(MatchFilter.ShouldRecord(Match('regular', 'TURF_WAR'), Settings), false);
    expect(MatchFilter.ShouldRecord(Match('private', 'AREA'), Settings), false);
    expect(MatchFilter.ShouldRecord(Match('anarchyOpen', 'AREA'), Settings), false);
    expect(MatchFilter.ShouldRecord(Match('salmon', 'REGULAR', Salmon: true), Settings), true);
    expect(MatchFilter.ShouldRecord(Match('highlight', 'HIGHLIGHT'), Settings), true);
    final Turf = Settings.Copy(<String, dynamic>{'recordTurf': true});
    expect(MatchFilter.ShouldRecord(Match('regular', 'TURF_WAR'), Turf), true);
    expect(MatchFilter.ShouldRecord(Match('splatfest', 'TRI_COLOR'), Turf), true);
    final Ranked = Settings.Copy(<String, dynamic>{'recordRanked': true});
    expect(MatchFilter.ShouldRecord(Match('event', 'AREA'), Ranked), true);
    expect(MatchFilter.ShouldRecord(Match('xBattle', 'LOFT'), Ranked), true);
  });

  test('Settings roundtrip keeps recording toggles', () {
    final Value = RecordSettings(RecordWork: false, RecordRanked: false, RecordTurf: true, RecordHighlight: false);
    final Next = RecordSettings.FromMap(Value.ToMap(), Value);
    expect(Next.RecordWork, false);
    expect(Next.RecordRanked, false);
    expect(Next.RecordTurf, true);
    expect(Next.RecordHighlight, false);
  });
}
