import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/config/Config.dart';
import 'package:splatoon3record/nso/Battle.dart';
import 'package:splatoon3record/nso/Service.dart';

void main() {
  test('Build Nintendo authorization request', () {
    final Auth = NSOService().BeginAuth();
    final Parsed = Uri.parse(Auth.Url);
    expect(Parsed.host, 'accounts.nintendo.com');
    expect(Parsed.queryParameters['client_id'], Config.NSOClientId);
    expect(Parsed.queryParameters['redirect_uri'], 'npf${Config.NSOClientId}://auth');
    expect(Parsed.queryParameters['response_type'], 'session_token_code');
    expect(Parsed.queryParameters['state'], Auth.State);
    expect(Parsed.queryParameters['session_token_code_challenge_method'], 'S256');
    expect(Auth.Verifier.isNotEmpty, true);
  });

  test('Normalize SplatNet detail', () {
    final Match = NSOBattle.FromDetail(<String, dynamic>{
      'data': <String, dynamic>{
        'vsHistoryDetail': <String, dynamic>{
          'id': 'detail-1',
          'vsMode': <String, dynamic>{'mode': 'BANKARA'},
          'vsRule': <String, dynamic>{'id': 'VnNSdWxlLTE=', 'name': '真格区域'},
          'bankaraMatch': <String, dynamic>{'mode': 'OPEN'},
          'judgement': 'WIN',
          'playedTime': '2026-10-24T14:08:07Z',
          'duration': 180,
        },
      },
    }, 'account-1', 'Tester');
    expect(Match, isNotNull);
    expect(Match!.Kind, 'anarchyOpen');
    expect(Match.Rule, 'AREA');
    expect(Match.Duration, 180000);
    expect(Match.EndAt - Match.StartAt, 180000);
    expect(Match.TimeExact, true);
    expect(Match.Key, 'account-1:detail-1');
  });
}








