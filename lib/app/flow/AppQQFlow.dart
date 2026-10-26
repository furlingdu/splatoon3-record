part of 'package:splatoon3record/app/AppController.dart';

extension AppQQFlow on AppController {
  Future<void> StartQQBot(String AppId, String Secret) async {
    await QQBotRef?.Stop();
    final Bot = QQBot(
      OnState: (Value) {
        QQState = Value;
        if (Value == 'connected') QQError = null;
        unawaited(Logs.App('qq state $Value'));
        PushStatus();
      },
      OnMessage: (OpenId, Content) => HandleQQ(OpenId, Content),
    );
    QQBotRef = Bot;
    QQState = 'connecting';
    Notify();
    await Bot.Start(AppId, Secret);
  }

  Future<void> StartQQLogin() async {
    if (QQState == 'connected') return;
    await QQBindRef?.Stop();
    final Bind = QQBind(
      OnQr: (Url) {
        QrCode = Url.isEmpty ? null : Url;
        PushStatus();
      },
      OnState: (Value) {
        QQState = Value;
        PushStatus();
      },
      OnSuccess: (AppId, Secret) async {
        QQAppId = AppId;
        QQSecret = Secret;
        QrCode = null;
        final Data = Map<String, dynamic>.from(Vault.Data);
        Data['qqAppId'] = AppId;
        Data['qqSecret'] = Secret;
        await Vault.Save(Data);
        await StartQQBot(AppId, Secret);
      },
    );
    QQBindRef = Bind;
    try {
      await Bind.Start();
    } catch (Cause) {
      QQState = 'error';
      QQError = '$Cause';
      Notice = QQError;
      Notify();
    }
  }

  Future<void> UnbindQQ() async {
    await QQBindRef?.Stop();
    QQBindRef = null;
    await QQBotRef?.Stop();
    QQBotRef = null;
    QQState = 'unbound';
    QrCode = null;
    QQError = null;
    final Data = Map<String, dynamic>.from(Vault.Data);
    Data.remove('qqAppId');
    Data.remove('qqSecret');
    await Vault.Save(Data);
    PushStatus();
  }

  Future<void> HandleQQ(String OpenId, String Content) async {
    final Bot = QQBotRef;
    if (Bot == null) return;
    var Command = Content.trim().split(RegExp(r'\s+')).first.toLowerCase();
    if (Command.startsWith('/')) Command = Command.substring(1);
    var ConfigRef = Configs.Current;
    if (Command == 'bind') {
      if (ConfigRef.QQOwner == null) {
        await Configs.Save(AppConfig(Settings: ConfigRef.Settings, PushEnabled: ConfigRef.PushEnabled, SetupDone: ConfigRef.SetupDone, QQOwner: OpenId, HandledIds: ConfigRef.HandledIds, Raw: ConfigRef.Raw));
        await Bot.SendText(OpenId, '绑定成功~ 欢迎使用Splatoon 3 Record项目！\n作者@澪度\n官方群聊：1109099716');
      } else if (ConfigRef.QQOwner == OpenId) {
        await Bot.SendText(OpenId, '你已绑定本机器人，无需重复绑定');
      } else {
        await Bot.SendText(OpenId, '机器人已绑定其他用户，请先解除现有绑定');
      }
      PushStatus();
      return;
    }
    if (ConfigRef.QQOwner != OpenId) {
      await Bot.SendText(OpenId, '请先发送 /bind 完成用户绑定');
      return;
    }
    if (Command == 'push') {
      final Enabled = !ConfigRef.PushEnabled;
      ConfigRef = AppConfig(Settings: ConfigRef.Settings.Copy(<String, dynamic>{'autoPush': Enabled}), PushEnabled: Enabled, SetupDone: ConfigRef.SetupDone, QQOwner: ConfigRef.QQOwner, HandledIds: ConfigRef.HandledIds, Raw: ConfigRef.Raw);
      await Configs.Save(ConfigRef);
      await Bot.SendText(OpenId, '自动推送已${Enabled ? '开启' : '关闭'}');
      PushStatus();
      return;
    }
    if (Command == 'status') {
      final Minutes = Status?.CacheStart == null ? 0 : ((Status?.CacheEnd ?? DateTime.now().millisecondsSinceEpoch) - Status!.CacheStart!) ~/ 60000;
      final Latest = Archive.Matches.isEmpty ? null : Archive.Matches.first;
      await Bot.SendText(OpenId, <String>[
        '录制：${Status?.RecordState ?? 'idle'}',
        'NSO：${Status?.NSOState ?? 'unbound'}',
        'QQBot：$QQState',
        '缓存：$Minutes 分钟',
        '最近对局：${Latest == null ? '无' : Formats.TimeText(Latest.EndAt)}',
      ].join('\n'));
      return;
    }
    if (Command == 'last' || Command == 'record') {
      if (Archive.Matches.isEmpty || Archive.Matches.first.VideoPath == null) {
        await Bot.SendText(OpenId, '尚无可发送的录像');
        return;
      }
      if (Command == 'record') {
        final Video = Archive.Matches.first;
        final Blurred = Video.BlurCopy ? Archive.BlurFile(Video.VideoPath) : null;
        final Path = Blurred != null && File(Blurred).existsSync() ? Blurred : Video.VideoPath!;
        try {
          await Bot.SendVideo(OpenId, Path);
          await Bot.SendText(OpenId, '录像已发送');
        } catch (Cause) {
          await Bot.SendText(OpenId, '录像发送失败：$Cause\n文件已保留在本地归档');
        }
        return;
      }
      await Bot.SendMarkdown(OpenId, QQMatchText(Archive.Matches.first));
      return;
    }
    await Bot.SendText(OpenId, '可用命令：/bind /record /last /push /status');
  }

  String QQMatchText(BattleMatch Match) {
    final Stats = <String>[
      '| 项目 | 内容 |',
      '| --- | --- |',
      '| 模式 | ${Formats.Kind(Match.Kind)} |',
      '| 规则 | ${Formats.Rule(Match.Rule)} |',
      '| 结果 | ${Match.IsDisconnected ? '掉线' : Formats.Result(Match.Result)} |',
      '| 时间 | ${Formats.DateTimeText(Match.EndAt)} |',
      '| 耗时 | ${Formats.Duration(Match.Duration)} |',
      '| 是否掉线 | ${Match.IsDisconnected ? '是' : '否'} |',
    ];
    return '# 新对局，${Match.VideoPath != null ? '已成功录制对局' : '未成功录制对局'}\n\n${Stats.join('\n')}';
  }

}








