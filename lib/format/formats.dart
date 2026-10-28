import 'dart:convert';

class Formats {
  static const Map<String, String> KindNames = <String, String>{
    'regular': '占地对战',
    'anarchyOpen': '蛮颓比赛（开放）',
    'anarchySeries': '蛮颓比赛（挑战）',
    'xBattle': 'X对战',
    'event': '活动挑战',
    'splatfest': '蛮颓祭',
    'private': '私房对战',
    'salmon': '鲑鱼跑',
    'unknown': '未知类型',
  };

  static const Map<String, String> RuleNames = <String, String>{
    'TURF_WAR': '占地对战',
    'AREA': '真格区域',
    'LOFT': '真格塔楼',
    'GOAL': '真格鱼虎对战',
    'CLAM': '真格蛤蜊',
    'TRI_COLOR': '三色占地对战',
    'REGULAR': '平时打工',
    'BIG_RUN': '大量发生',
    'TEAM_CONTEST': '团队竞赛',
    'COOP_NORMAL': '平时打工',
  };

  static String Kind(String Value) => KindNames[Value] ?? KindNames['unknown']!;

  static String Rule(String Value) {
    if (Value.isEmpty || Value.startsWith('[object')) return '未知规则';
    return RuleNames[Value.toUpperCase()] ?? Value;
  }

  static String Result(String Value) {
    if (RegExp('WIN', caseSensitive: false).hasMatch(Value)) return '胜利';
    if (RegExp('LOSE', caseSensitive: false).hasMatch(Value)) return '失败';
    if (RegExp('DRAW', caseSensitive: false).hasMatch(Value)) return '平局';
    if (RegExp('EXEMPTED', caseSensitive: false).hasMatch(Value)) return '无效';
    return '未知结果';
  }

  static String Duration(int Milliseconds) {
    final Total = (Milliseconds / 1000).round().clamp(0, 1 << 31);
    final Minutes = Total ~/ 60;
    final Seconds = Total % 60;
    return '$Minutes:${Seconds.toString().padLeft(2, '0')}';
  }

  static String DateTimeText(int Milliseconds) {
    final Date = DateTime.fromMillisecondsSinceEpoch(Milliseconds);
    return '${Date.year}/${Date.month}/${Date.day} ${TimeText(Milliseconds)}';
  }

  static String ShortDateTime(int Milliseconds) {
    final Date = DateTime.fromMillisecondsSinceEpoch(Milliseconds);
    final Hour = Date.hour.toString().padLeft(2, '0');
    final Minute = Date.minute.toString().padLeft(2, '0');
    return '${Date.month}/${Date.day} $Hour:$Minute';
  }

  static String TimeText(int Milliseconds) {
    final Date = DateTime.fromMillisecondsSinceEpoch(Milliseconds);
    return '${Date.hour.toString().padLeft(2, '0')}:${Date.minute.toString().padLeft(2, '0')}:${Date.second.toString().padLeft(2, '0')}';
  }

  static String Fps(num Value) {
    final Rounded = double.parse(Value.toDouble().toStringAsFixed(2));
    return '${Rounded == Rounded.roundToDouble() ? Rounded.toInt() : Rounded} fps';
  }

  static String Resolution(int Width, int Height) => '$Width x $Height';

  static String OrientationName(String Value) {
    const Map<String, String> Names = <String, String>{
      'auto': '自动识别',
      'landscape': '横屏',
      'portrait': '竖屏',
      'landscapeFlipped': '横屏倒置',
      'portraitFlipped': '竖屏倒置',
    };
    return Names[Value] ?? Names['auto']!;
  }

  static String Size(int Bytes) {
    if (Bytes <= 0) return '0 MB';
    return '${(Bytes / 1048576).toStringAsFixed(1)} MB';
  }

  static String MatchTitle(String KindValue, int EndAt) => '${Kind(KindValue)}-${DateTimeText(EndAt)}';

  static String MatchFileName(String KindValue, int EndAt, String? AccountId) {
    final Date = DateTime.fromMillisecondsSinceEpoch(EndAt);
    String Pad(int Value) => Value.toString().padLeft(2, '0');
    final Stamp = '${Date.year}${Pad(Date.month)}${Pad(Date.day)}-${Pad(Date.hour)}${Pad(Date.minute)}${Pad(Date.second)}';
    final Suffix = AccountId == null || AccountId.isEmpty ? '' : '-${ShortHash(AccountId)}';
    return '${Kind(KindValue)}-$Stamp$Suffix';
  }

  static String ShortHash(String Value) {
    var Hash = 2166136261;
    for (final Byte in utf8.encode(Value)) {
      Hash ^= Byte;
      Hash = (Hash * 16777619) & 0xffffffff;
    }
    return Hash.toRadixString(16).padLeft(8, '0').substring(0, 6);
  }

  static String Paint(Object? Value) {
    final Text = '${Value ?? ''}';
    if (Text.isEmpty) return Text;
    final Number = num.tryParse(Text);
    return Number == null ? Text : '${Text}p';
  }

  static String FileFormat(String Value) {
    if (Value.isEmpty) return '未开始采集';
    return Value.replaceFirst('video/', '').replaceAll(';codecs=', ' · ').replaceAll('"', '');
  }

  static String RtmpState(String State) {
    const Map<String, String> Names = <String, String>{
      'idle': '未启动',
      'listening': '等待推流',
      'live': '已接收',
      'error': '异常',
    };
    return Names[State] ?? State;
  }

  static String PushState(String State) {
    const Map<String, String> Names = <String, String>{
      'idle': '未推流',
      'starting': '正在启动',
      'live': '推流中',
      'error': '推流异常',
    };
    return Names[State] ?? State;
  }

  static String MatchState(String State) {
    const Map<String, String> Names = <String, String>{
      'unbound': '未绑定',
      'connecting': '登录中',
      'connected': '已连接',
      'expired': '已过期，请重新登录',
      'error': '连接异常',
    };
    return Names[State] ?? '未绑定';
  }

  static String BindingState(String State) {
    const Map<String, String> Names = <String, String>{
      'unbound': '未绑定',
      'connecting': '等待操作',
      'connected': '已连接',
      'expired': '已过期，需要重新登录',
      'error': '连接异常',
    };
    return Names[State] ?? State;
  }
}









