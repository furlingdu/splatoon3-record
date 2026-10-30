import '../domain/models.dart';

abstract final class MatchFilter {
  static bool ShouldRecord(BattleMatch Match, RecordSettings Value) {
    if (Match.Kind == 'highlight') return true;
    if (Match.IsSalmon || Match.Kind == 'salmon') return Value.RecordWork;
    if (Match.Kind == 'private' || Match.Kind == 'event') return Value.RecordRanked;
    if (Match.Kind == 'regular' || Match.Kind == 'splatfest') return Value.RecordTurf;
    if (Match.Rule == 'TURF_WAR' || Match.Rule == 'TRI_COLOR') return Value.RecordTurf;
    return Value.RecordRanked;
  }

  static String SkipReason(BattleMatch Match) {
    if (Match.IsSalmon || Match.Kind == 'salmon') return '未开启打工模式录制';
    if (Match.Kind == 'private' || Match.Kind == 'event') return '未开启真格模式录制';
    if (Match.Kind == 'regular' || Match.Kind == 'splatfest') return '未开启涂地模式录制';
    if (Match.Rule == 'TURF_WAR' || Match.Rule == 'TRI_COLOR') return '未开启涂地模式录制';
    return '未开启真格模式录制';
  }
}
