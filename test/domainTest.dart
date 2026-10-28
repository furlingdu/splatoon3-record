import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/domain/models.dart';
import 'package:splatoon3record/format/formats.dart';
import 'package:splatoon3record/match/stats.dart';

void main() {
  test('Formats match legacy names', () {
    expect(Formats.Kind('anarchySeries'), '蛮颓比赛（挑战）');
    expect(Formats.Rule('TURF_WAR'), '占地对战');
    expect(Formats.Result('WIN'), '胜利');
    expect(Formats.Duration(90000), '1:30');
    expect(Formats.MatchFileName('regular', DateTime(2026, 10, 24, 21, 30, 5).millisecondsSinceEpoch, 'abc'), '占地对战-20261024-213005-${Formats.ShortHash('abc')}');
  });

  test('Settings sanitizes values and keeps defaults', () {
    final Base = RecordSettings();
    final Next = RecordSettings.FromMap(<String, dynamic>{
      'captureMode': 'bad',
      'rtmpPort': 1,
      'width': 9000,
      'height': 2,
      'fps': 999,
      'quality': 18,
      'captureFormat': 'bad',
      'encoder': 'bad',
      'themeColor': 'bad',
      'backgroundDim': 200,
    }, Base);
    expect(Next.CaptureMode, 'internal');
    expect(Next.RtmpPort, 1024);
    expect(Next.Width, 7680);
    expect(Next.Height, 180);
    expect(Next.Fps, 240);
    expect(Next.Quality, 18);
    expect(Next.CaptureFormat, 'nv12');
    expect(Next.Encoder, 'auto');
    expect(Next.ThemeColor, Base.ThemeColor);
    expect(Next.BackgroundDim, 100);
  });

  test('Config preserves unknown fields', () {
    final Config = AppConfig.FromMap(<String, dynamic>{
      'settings': <String, dynamic>{'width': 1280},
      'setupDone': true,
      'futureField': 'kept',
      'handledIds': <String>['a', 'a', 'legacy:b'],
    });
    final Encoded = Config.ToMap();
    expect(Encoded['futureField'], 'kept');
    expect(Encoded['settings']['width'], 1280);
    expect(Encoded['setupDone'], true);
  });

  test('Battle key uses account id', () {
    final Match = BattleMatch.FromMap(<String, dynamic>{
      'matchId': 'm1',
      'accountId': 'a1',
      'kind': 'regular',
      'startAt': 1,
      'endAt': 2,
      'duration': 1,
    });
    expect(Match.Key, 'a1:m1');
    expect(Match.ToMap()['matchId'], 'm1');
  });

  test('Match stats read personal result', () {
    final Match = BattleMatch.FromMap(<String, dynamic>{
      'matchId': 'm1',
      'kind': 'regular',
      'startAt': 1,
      'endAt': 2,
      'duration': 1,
      'rawData': <String, dynamic>{
        'data': <String, dynamic>{
          'vsHistoryDetail': <String, dynamic>{
            'myTeam': <String, dynamic>{
              'players': <dynamic>[
                <String, dynamic>{'isMyself': true, 'paint': 800, 'result': <String, dynamic>{'kill': 5, 'death': 2, 'special': 1}},
              ],
            },
          },
        },
      },
    });
    expect(MatchStats.Personal(Match), (5, 2, 1, 800));
    expect(MatchStats.Text(Match), contains('击杀 5'));
  });
}







