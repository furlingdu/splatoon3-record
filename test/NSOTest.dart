import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/config/Config.dart';
import 'package:splatoon3record/nso/Battle.dart';
import 'package:splatoon3record/nso/NSOAuthCallback.dart';
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

  test('Parse Nintendo callback from fragment', () {
    final Callback = NSOAuthCallback.Parse(Uri.parse('npf71b963c1b7b6d119://auth#session_token_code=abc.def&state=xyz'));
    expect(Callback, isNotNull);
    expect(Callback!.Code, 'abc.def');
    expect(Callback.State, 'xyz');
    expect(Callback.Error, '');
  });

  test('Parse Nintendo callback from query and fragment', () {
    final Callback = NSOAuthCallback.Parse(Uri.parse('npf71b963c1b7b6d119://auth?state=from-query&session_token_code=query-code#state=from-fragment&session_token_code=fragment-code'));
    expect(Callback, isNotNull);
    expect(Callback!.Code, 'fragment-code');
    expect(Callback.State, 'from-fragment');
  });

  test('Parse encoded Nintendo callback and error', () {
    final Callback = NSOAuthCallback.Parse(Uri.parse('npf71b963c1b7b6d119://auth#state=a%2Bb&session_token_code=code%2Fone'));
    expect(Callback, isNotNull);
    expect(Callback!.Code, 'code/one');
    expect(Callback.State, 'a+b');
    final Failure = NSOAuthCallback.Parse(Uri.parse('npf71b963c1b7b6d119://auth#error=access_denied&error_description=User%20cancelled'));
    expect(Failure, isNotNull);
    expect(Failure!.Error, 'User cancelled');
  });

  test('Ignore non Nintendo callback', () {
    expect(NSOAuthCallback.Parse(Uri.parse('https://example.com/auth#session_token_code=x')), isNull);
    expect(NSOAuthCallback.Parse(Uri.parse('npf71b963c1b7b6d119://other#session_token_code=x')), isNull);
  });

  test('Parse pasted callback input', () {
    const Original = 'npf71b963c1b7b6d119://auth#state=paste-state&session_token_code=paste-code';
    final Encoded = Uri.encodeComponent(Original);
    final Wrapped = NSOAuthCallback.ParseInput('选择此人 $Encoded');
    expect(Wrapped, isNotNull);
    expect(Wrapped!.Code, 'paste-code');
    expect(Wrapped.State, 'paste-state');
    final Query = NSOAuthCallback.ParseInput('state=query-state&session_token_code=query-code');
    expect(Query, isNotNull);
    expect(Query!.Code, 'query-code');
    expect(Query.State, 'query-state');
    final Fragment = NSOAuthCallback.ParseInput('#state=fragment-state&session_token_code=fragment-code');
    expect(Fragment, isNotNull);
    expect(Fragment!.Code, 'fragment-code');
    expect(Fragment.State, 'fragment-state');
    expect(NSOAuthCallback.ParseInput('https://example.com/'), isNull);
    expect(NSOAuthCallback.ParseInput('no callback here'), isNull);
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








