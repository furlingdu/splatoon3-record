import 'dart:convert';

import '../domain/models.dart';

class NSOBattle {
  static BattleMatch? FromDetail(Map<String, dynamic> Raw, String AccountId, String Nickname) {
    final Data = Raw['data'] is Map ? Raw['data'] as Map : Raw;
    final Detail = Data['vsHistoryDetail'] is Map ? Data['vsHistoryDetail'] as Map : Data;
    final Id = '${Detail['id'] ?? ''}';
    if (Id.isEmpty) return null;
    final Mode = Detail['vsMode'] is Map ? '${(Detail['vsMode'] as Map)['mode'] ?? ''}' : '${Detail['vsMode'] ?? ''}';
    if (Mode.contains('COOP')) return null;
    final Rule = Detail['vsRule'] is Map ? Map<String, dynamic>.from(Detail['vsRule'] as Map) : <String, dynamic>{};
    final RuleKey = Rule['rule'] is String && '${Rule['rule']}'.isNotEmpty ? '${Rule['rule']}' : MapRule(Rule);
    final Bankara = Detail['bankaraMatch'] is Map ? '${(Detail['bankaraMatch'] as Map)['mode'] ?? ''}' : '';
    final Kind = MapKind(Mode, Bankara);
    final Played = DateTime.tryParse('${Detail['playedTime'] ?? Detail['startTime'] ?? ''}')?.millisecondsSinceEpoch ?? 0;
    final Duration = ((Detail['duration'] as num?)?.toInt() ?? 0) * 1000;
    final Start = Played > 0 ? Played + 22000 : 0;
    final End = Start > 0 && Duration > 0 ? Start + Duration : 0;
    final Result = '${Detail['judgement'] ?? ''}';
    return BattleMatch(
      Raw: Raw,
      MatchId: Id,
      Kind: Kind,
      Mode: Mode,
      Rule: RuleKey,
      StartAt: Start,
      EndAt: End,
      Duration: Duration,
      Result: Result,
      IsDisconnected: Result.contains('DEEMED_LOSE') || Result.contains('EXEMPTED_LOSE'),
      IsSalmon: false,
      VideoPath: null,
      AccountId: AccountId,
      AccountNickname: Nickname,
      SkipReason: null,
      BlurCopy: false,
      TimeExact: Start > 0 && End > Start,
      Key: '$AccountId:$Id',
    );
  }

  static String MapKind(String Mode, String Bankara) {
    final Text = Mode.toUpperCase();
    if (Text.contains('PRIVATE')) return 'private';
    if (Text.contains('FEST')) return 'splatfest';
    if (Text.contains('X_MATCH') || Text.contains('X MATCH')) return 'xBattle';
    if (Bankara.contains('CHALLENGE')) return 'anarchySeries';
    if (Bankara.contains('OPEN')) return 'anarchyOpen';
    if (Text.contains('BANKARA')) return 'anarchyOpen';
    if (Text.contains('LEAGUE') || Text.contains('EVENT')) return 'event';
    if (Text.contains('REGULAR') || Text.contains('TURF')) return 'regular';
    return 'unknown';
  }

  static String MapRule(Map<String, dynamic> Rule) {
    final Name = '${Rule['name'] ?? ''}'.toLowerCase();
    if (Name.contains('占地') || Name.contains('ナワバリ') || Name.contains('turf')) return 'TURF_WAR';
    if (Name.contains('区域') || Name.contains('エリア') || Name.contains('zone')) return 'AREA';
    if (Name.contains('塔') || Name.contains('ヤグラ') || Name.contains('tower')) return 'LOFT';
    if (Name.contains('鱼') || Name.contains('ガチホコ') || Name.contains('rainmaker')) return 'GOAL';
    if (Name.contains('蛤蜊') || Name.contains('アサリ') || Name.contains('clam')) return 'CLAM';
    final Id = '${Rule['id'] ?? ''}';
    try {
      final Decoded = utf8.decode(base64Decode(Id));
      if (Decoded.endsWith('-1')) return 'AREA';
      if (Decoded.endsWith('-2')) return 'LOFT';
      if (Decoded.endsWith('-4')) return 'GOAL';
      if (Decoded.endsWith('-8')) return 'CLAM';
      if (Decoded.endsWith('-32')) return 'TURF_WAR';
    } catch (_) {}
    return Id.isEmpty ? 'TURF_WAR' : Id;
  }
}








