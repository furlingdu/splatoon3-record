import '../domain/models.dart';

class MatchStats {
  static (int, int, int, int) Personal(BattleMatch Match) {
    final Root = Match.Raw['rawData'] is Map ? Match.Raw['rawData'] as Map : Match.Raw;
    final Data = Root['data'] is Map ? Root['data'] as Map : Root;
    final Detail = Data['vsHistoryDetail'] is Map
        ? Data['vsHistoryDetail'] as Map
        : Data['coopHistoryDetail'] is Map
            ? Data['coopHistoryDetail'] as Map
            : Data;
    final MyTeam = Detail['myTeam'] is Map ? Detail['myTeam'] as Map : null;
    final Players = MyTeam?['players'] is List ? MyTeam!['players'] as List : const <dynamic>[];
    for (final Player in Players) {
      if (Player is! Map || Player['isMyself'] != true) continue;
      final Result = Player['result'] is Map ? Player['result'] as Map : const <String, dynamic>{};
      final Kill = (Result['kill'] as num?)?.toInt() ?? 0;
      return (
        Kill,
        (Result['death'] as num?)?.toInt() ?? 0,
        (Result['special'] as num?)?.toInt() ?? 0,
        (Player['paint'] as num?)?.toInt() ?? 0,
      );
    }
    final Coop = Detail['myResult'] is Map ? Detail['myResult'] as Map : const <String, dynamic>{};
    final CoopPlayer = Coop['player'] is Map ? Coop['player'] as Map : const <String, dynamic>{};
    return ((Coop['defeatEnemyCount'] as num?)?.toInt() ?? 0, 0, 0, (CoopPlayer['paint'] as num?)?.toInt() ?? 0);
  }

  static String Text(BattleMatch Match) {
    final Value = Personal(Match);
    final Kd = Value.$2 == 0 ? '-' : (Value.$1 / Value.$2).toStringAsFixed(2);
    return '个人 K/D $Kd · 击杀 ${Value.$1} · 死亡 ${Value.$2} · 大招 ${Value.$3} · 涂地 ${Value.$4}p';
  }
}








