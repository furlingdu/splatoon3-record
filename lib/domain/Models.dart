import 'dart:convert';
import 'dart:io';
import 'dart:math';

class RecordSettings {
  RecordSettings({
    this.CaptureMode = 'internal',
    this.RtmpPort = 36761,
    this.RtmpStreamKey = '',
    this.RtmpPushUrl = '',
    this.RtmpPushKey = '',
    this.VideoDevice = '',
    this.AudioDevice = '',
    this.DesktopAudio = false,
    this.MicAudio = false,
    this.MicDevice = '',
    this.CaptureFormat = 'nv12',
    this.Width = 1920,
    this.Height = 1080,
    this.Fps = 60,
    this.FlipVertical = false,
    this.Encoder = 'auto',
    this.Quality = 22,
    this.SaveDir = '',
    this.AutoPush = true,
    this.AutoRecord = true,
    this.AutoLaunch = false,
    this.BlurNickname = false,
    this.MonitorAudio = false,
    this.PollSeconds = 10,
    this.UpdateProxy = false,
    this.UpdateCheck = true,
    this.ThemeColor = '#4285f4',
    this.BackgroundPath = '',
    this.BackgroundDim = 40,
    this.MobileSource = 'uvc',
    this.MobileDevice = '',
    this.MobileAudio = true,
    this.MobileAudioDevice = '',
    this.MobileOrientation = 'auto',
  });

  String CaptureMode;
  int RtmpPort;
  String RtmpStreamKey;
  String RtmpPushUrl;
  String RtmpPushKey;
  String VideoDevice;
  String AudioDevice;
  bool DesktopAudio;
  bool MicAudio;
  String MicDevice;
  String CaptureFormat;
  int Width;
  int Height;
  int Fps;
  bool FlipVertical;
  String Encoder;
  int Quality;
  String SaveDir;
  bool AutoPush;
  bool AutoRecord;
  bool AutoLaunch;
  bool BlurNickname;
  bool MonitorAudio;
  int PollSeconds;
  bool UpdateProxy;
  bool UpdateCheck;
  String ThemeColor;
  String BackgroundPath;
  int BackgroundDim;
  String MobileSource;
  String MobileDevice;
  bool MobileAudio;
  String MobileAudioDevice;
  String MobileOrientation;

  static RecordSettings FromMap(Map<String, dynamic> Data, [RecordSettings? Current]) {
    final Fallback = Current ?? RecordSettings();
    int Number(Object? Value, int Min, int Max, int Default) {
      final Parsed = Value is num ? Value.toInt() : int.tryParse('${Value ?? ''}');
      if (Parsed == null) return Default;
      return Parsed.clamp(Min, Max);
    }

    String Text(Object? Value, [String Default = '']) {
      if (Value is! String) return Default;
      final Clean = Value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
      return Clean.length > 300 ? Clean.substring(0, 300) : Clean;
    }

    bool Flag(Object? Value, bool Default) {
      if (Value == null) return Default;
      if (Value is bool) return Value;
      return Value == 'true' || Value == 1;
    }

    final Encoder = Text(Data['encoder'], Fallback.Encoder);
    final CaptureMode = Text(Data['captureMode'], Fallback.CaptureMode);
    final CaptureFormat = Text(Data['captureFormat'], Fallback.CaptureFormat);
    final ThemeColor = Text(Data['themeColor'], Fallback.ThemeColor);
    final MobileSource = Text(Data['mobileSource'], Fallback.MobileSource);
    final MobileOrientation = Text(Data['mobileOrientation'], Fallback.MobileOrientation);
    final Quality = Number(Data['quality'], 0, 51, Fallback.Quality);
    final Port = Number(Data['rtmpPort'], 1024, 65535, Fallback.RtmpPort);
    final Key = Text(Data['rtmpStreamKey'], Fallback.RtmpStreamKey);
    return RecordSettings(
      CaptureMode: CaptureMode == 'rtmp' ? 'rtmp' : 'internal',
      RtmpPort: Port,
      RtmpStreamKey: RegExp(r'^[A-Za-z0-9_-]{4,64}$').hasMatch(Key)
          ? Key
          : RegExp(r'^[A-Za-z0-9_-]{4,64}$').hasMatch(Fallback.RtmpStreamKey)
              ? Fallback.RtmpStreamKey
              : RandomKey(),
      RtmpPushUrl: RegExp(r'^rtmps?://').hasMatch(Text(Data['rtmpPushUrl'])) ? Text(Data['rtmpPushUrl']) : '',
      RtmpPushKey: Text(Data['rtmpPushKey']).replaceAll(RegExp(r'\s+'), ''),
      VideoDevice: Text(Data['videoDevice'], Fallback.VideoDevice),
      AudioDevice: Text(Data['audioDevice'], Fallback.AudioDevice),
      DesktopAudio: Flag(Data['desktopAudio'], Fallback.DesktopAudio),
      MicAudio: Flag(Data['micAudio'], Fallback.MicAudio),
      MicDevice: Text(Data['micDevice'], Fallback.MicDevice),
      CaptureFormat: CaptureFormat == 'yuy2' ? 'yuy2' : CaptureFormat == 'mjpeg' ? 'mjpeg' : 'nv12',
      Width: Number(Data['width'], 320, 7680, Fallback.Width),
      Height: Number(Data['height'], 180, 4320, Fallback.Height),
      Fps: Number(Data['fps'], 1, 240, Fallback.Fps),
      FlipVertical: Flag(Data['flipVertical'], Fallback.FlipVertical),
      Encoder: const ['auto', 'nvidia', 'amd', 'intel', 'software'].contains(Encoder) ? Encoder : 'auto',
      Quality: [18, 22, 28].reduce((Left, Right) => (Left - Quality).abs() <= (Right - Quality).abs() ? Left : Right),
      SaveDir: Text(Data['saveDir'], Fallback.SaveDir),
      AutoPush: Flag(Data['autoPush'], Fallback.AutoPush),
      AutoRecord: Flag(Data['autoRecord'], Fallback.AutoRecord),
      AutoLaunch: Flag(Data['autoLaunch'], Fallback.AutoLaunch),
      BlurNickname: Flag(Data['blurNickname'], Fallback.BlurNickname),
      MonitorAudio: Flag(Data['monitorAudio'], Fallback.MonitorAudio),
      PollSeconds: Number(Data['pollSeconds'], 10, 600, Fallback.PollSeconds),
      UpdateProxy: Flag(Data['updateProxy'], Fallback.UpdateProxy),
      UpdateCheck: Flag(Data['updateCheck'], Fallback.UpdateCheck),
      ThemeColor: RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(ThemeColor) ? ThemeColor.toLowerCase() : Fallback.ThemeColor,
      BackgroundPath: Text(Data['backgroundPath'], Fallback.BackgroundPath),
      BackgroundDim: Number(Data['backgroundDim'], 0, 100, Fallback.BackgroundDim),
      MobileSource: const ['uvc', 'external', 'camera'].contains(MobileSource) ? MobileSource : 'uvc',
      MobileDevice: Text(Data['mobileDevice'], Fallback.MobileDevice),
      MobileAudio: Flag(Data['mobileAudio'], Fallback.MobileAudio),
      MobileAudioDevice: Text(Data['mobileAudioDevice'], Fallback.MobileAudioDevice),
      MobileOrientation: const ['auto', 'landscape', 'portrait', 'landscapeFlipped', 'portraitFlipped'].contains(MobileOrientation) ? MobileOrientation : 'auto',
    );
  }

  static String RandomKey() {
    const Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
    final Generator = Random.secure();
    return List.generate(12, (_) => Chars[Generator.nextInt(Chars.length)]).join();
  }

  Map<String, dynamic> ToMap() => {
        'captureMode': CaptureMode,
        'rtmpPort': RtmpPort,
        'rtmpStreamKey': RtmpStreamKey,
        'rtmpPushUrl': RtmpPushUrl,
        'rtmpPushKey': RtmpPushKey,
        'videoDevice': VideoDevice,
        'audioDevice': AudioDevice,
        'desktopAudio': DesktopAudio,
        'micAudio': MicAudio,
        'micDevice': MicDevice,
        'captureFormat': CaptureFormat,
        'width': Width,
        'height': Height,
        'fps': Fps,
        'flipVertical': FlipVertical,
        'encoder': Encoder,
        'quality': Quality,
        'saveDir': SaveDir,
        'autoPush': AutoPush,
        'autoRecord': AutoRecord,
        'autoLaunch': AutoLaunch,
        'blurNickname': BlurNickname,
        'monitorAudio': MonitorAudio,
        'pollSeconds': PollSeconds,
        'updateProxy': UpdateProxy,
        'updateCheck': UpdateCheck,
        'themeColor': ThemeColor,
        'backgroundPath': BackgroundPath,
        'backgroundDim': BackgroundDim,
        'mobileSource': MobileSource,
        'mobileDevice': MobileDevice,
        'mobileAudio': MobileAudio,
        'mobileAudioDevice': MobileAudioDevice,
        'mobileOrientation': MobileOrientation,
      };

  RecordSettings Copy([Map<String, dynamic>? Part]) {
    final DataMap = ToMap();
    if (Part != null) DataMap.addAll(Part);
    return RecordSettings.FromMap(DataMap, this);
  }
}

class AppConfig {
  AppConfig({
    required this.Settings,
    required this.PushEnabled,
    required this.SetupDone,
    required this.QQOwner,
    required this.HandledIds,
    required this.Raw,
  });

  RecordSettings Settings;
  bool PushEnabled;
  bool SetupDone;
  String? QQOwner;
  List<String> HandledIds;
  Map<String, dynamic> Raw;

  static AppConfig Defaults([RecordSettings? Values]) {
    final Use = Values ?? RecordSettings();
    return AppConfig(
      Settings: Use,
      PushEnabled: true,
      SetupDone: false,
      QQOwner: null,
      HandledIds: [],
      Raw: <String, dynamic>{},
    );
  }

  static AppConfig FromMap(Map<String, dynamic> Data) {
    final RawSettings = Data['settings'] is Map ? Map<String, dynamic>.from(Data['settings'] as Map) : <String, dynamic>{};
    final Use = RecordSettings.FromMap(RawSettings);
    final Handled = Data['handledIds'] is List ? (Data['handledIds'] as List).map((Item) => '$Item').toList() : <String>[];
    return AppConfig(
      Settings: Use,
      PushEnabled: Data['pushEnabled'] is bool ? Data['pushEnabled'] as bool : Use.AutoPush,
      SetupDone: Data['setupDone'] == true,
      QQOwner: Data['qqOwner'] is String ? Data['qqOwner'] as String : null,
      HandledIds: Handled,
      Raw: Map<String, dynamic>.from(Data),
    );
  }

  Map<String, dynamic> ToMap() {
    final DataMap = Map<String, dynamic>.from(Raw);
    DataMap['settings'] = Settings.ToMap();
    DataMap['pushEnabled'] = PushEnabled;
    DataMap['setupDone'] = SetupDone;
    if (QQOwner != null) DataMap['qqOwner'] = QQOwner;
    DataMap['handledIds'] = HandledIds;
    return DataMap;
  }
}

class BattleMatch {
  BattleMatch({
    required this.Raw,
    required this.MatchId,
    required this.Kind,
    required this.Mode,
    required this.Rule,
    required this.StartAt,
    required this.EndAt,
    required this.Duration,
    required this.Result,
    required this.IsDisconnected,
    required this.IsSalmon,
    required this.VideoPath,
    required this.AccountId,
    required this.AccountNickname,
    required this.SkipReason,
    required this.BlurCopy,
    required this.TimeExact,
    required this.Key,
  });

  Map<String, dynamic> Raw;
  String MatchId;
  String Kind;
  String Mode;
  String Rule;
  int StartAt;
  int EndAt;
  int Duration;
  String Result;
  bool IsDisconnected;
  bool IsSalmon;
  String? VideoPath;
  String? AccountId;
  String? AccountNickname;
  String? SkipReason;
  bool BlurCopy;
  bool TimeExact;
  String Key;

  static BattleMatch FromMap(Map<String, dynamic> Data, [String? FallbackKey]) {
    final KeyValue = Data['key'] is String && (Data['key'] as String).isNotEmpty ? Data['key'] as String : FallbackKey;
    final Account = Data['accountId'] is String ? Data['accountId'] as String : null;
    final MatchId = Data['matchId'] is String ? Data['matchId'] as String : '';
    final StartAt = Data['startAt'] is num ? (Data['startAt'] as num).toInt() : 0;
    final EndAt = Data['endAt'] is num ? (Data['endAt'] as num).toInt() : 0;
    return BattleMatch(
      Raw: Map<String, dynamic>.from(Data),
      MatchId: MatchId,
      Kind: Data['kind'] is String ? Data['kind'] as String : 'unknown',
      Mode: Data['mode'] is String ? Data['mode'] as String : '',
      Rule: Data['rule'] is String ? Data['rule'] as String : '',
      StartAt: StartAt,
      EndAt: EndAt,
      Duration: Data['duration'] is num ? (Data['duration'] as num).toInt() : 0,
      Result: Data['result'] is String ? Data['result'] as String : '',
      IsDisconnected: Data['isDisconnected'] == true,
      IsSalmon: Data['isSalmon'] == true || Data['kind'] == 'salmon',
      VideoPath: Data['videoPath'] is String && (Data['videoPath'] as String).isNotEmpty ? Data['videoPath'] as String : null,
      AccountId: Account,
      AccountNickname: Data['accountNickname'] is String ? Data['accountNickname'] as String : null,
      SkipReason: Data['skipReason'] is String ? Data['skipReason'] as String : null,
      BlurCopy: Data['blurCopy'] == true,
      TimeExact: Data['timeExact'] == true,
      Key: KeyValue != null && KeyValue.isNotEmpty ? KeyValue : ((Account != null && Account.isNotEmpty) ? '$Account:$MatchId' : MatchId),
    );
  }

  bool get HasVideo {
    final Value = VideoPath;
    if (Value == null || Value.isEmpty) return false;
    try {
      final FileRef = File(Value);
      return FileRef.existsSync() && FileRef.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> ToMap() {
    final DataMap = Map<String, dynamic>.from(Raw);
    DataMap['matchId'] = MatchId;
    DataMap['kind'] = Kind;
    DataMap['mode'] = Mode;
    DataMap['rule'] = Rule;
    DataMap['startAt'] = StartAt;
    DataMap['endAt'] = EndAt;
    DataMap['duration'] = Duration;
    DataMap['result'] = Result;
    DataMap['isDisconnected'] = IsDisconnected;
    DataMap['isSalmon'] = IsSalmon;
    DataMap['timeExact'] = TimeExact;
    if (VideoPath != null) DataMap['videoPath'] = VideoPath;
    if (AccountId != null) DataMap['accountId'] = AccountId;
    if (AccountNickname != null) DataMap['accountNickname'] = AccountNickname;
    if (SkipReason != null) DataMap['skipReason'] = SkipReason;
    return DataMap;
  }

  BattleMatch Copy([Map<String, dynamic>? Part]) {
    final DataMap = ToMap();
    if (Part != null) DataMap.addAll(Part);
    return BattleMatch.FromMap(DataMap, Key);
  }
}

class CaptureDevice {
  CaptureDevice({required this.Id, required this.Name, required this.Kind, this.MaxWidth, this.MaxHeight, this.MaxFps});

  String Id;
  String Name;
  String Kind;
  int? MaxWidth;
  int? MaxHeight;
  int? MaxFps;

  Map<String, dynamic> ToMap() => {'id': Id, 'name': Name, 'kind': Kind, 'maxWidth': MaxWidth, 'maxHeight': MaxHeight, 'maxFps': MaxFps};
}

class CaptureMode {
  CaptureMode({required this.Format, required this.Width, required this.Height, required this.MinFps, required this.MaxFps});

  String Format;
  int Width;
  int Height;
  int MinFps;
  int MaxFps;

  String get Label => '$Width x $Height @ $MaxFps fps';
}

class VideoRecord {
  VideoRecord({
    required this.FilePath,
    required this.StartAt,
    required this.EndAt,
    required this.Width,
    required this.Height,
    required this.Fps,
    required this.Encoder,
    required this.HasAudio,
    required this.Flip,
  });

  String FilePath;
  int StartAt;
  int EndAt;
  int Width;
  int Height;
  int Fps;
  String Encoder;
  bool HasAudio;
  bool Flip;

  Map<String, dynamic> ToMap() => {
        'filePath': FilePath,
        'startAt': StartAt,
        'endAt': EndAt,
        'width': Width,
        'height': Height,
        'fps': Fps,
        'encoder': Encoder,
        'hasAudio': HasAudio,
        'flip': Flip,
      };
}

class NSOAccount {
  NSOAccount({
    required this.Id,
    required this.Nickname,
    required this.Session,
    required this.Token,
    required this.AddedAt,
    this.LastRefreshAt,
    this.State = 'connected',
    this.Error,
    this.LastMatchAt,
  });

  String Id;
  String Nickname;
  String Session;
  NSOToken Token;
  int AddedAt;
  int? LastRefreshAt;
  String State;
  String? Error;
  int? LastMatchAt;

  Map<String, dynamic> ToMap() => {
        'id': Id,
        'nickname': Nickname,
        'session': Session,
        'token': Token.ToMap(),
        'addedAt': AddedAt,
        if (LastRefreshAt != null) 'lastRefreshAt': LastRefreshAt,
      };

  static NSOAccount FromMap(Map<String, dynamic> Data) => NSOAccount(
        Id: '${Data['id'] ?? ''}',
        Nickname: '${Data['nickname'] ?? 'Nintendo 账号'}',
        Session: '${Data['session'] ?? ''}',
        Token: NSOToken.FromMap(Data['token'] is Map ? Map<String, dynamic>.from(Data['token'] as Map) : {}),
        AddedAt: Data['addedAt'] is num ? (Data['addedAt'] as num).toInt() : DateTime.now().millisecondsSinceEpoch,
        LastRefreshAt: Data['lastRefreshAt'] is num ? (Data['lastRefreshAt'] as num).toInt() : null,
      );
}

class NSOToken {
  NSOToken({
    required this.BulletToken,
    required this.GToken,
    required this.Language,
    required this.Country,
    required this.UserAgent,
    required this.ExpiresAt,
  });

  String BulletToken;
  String GToken;
  String Language;
  String Country;
  String UserAgent;
  int ExpiresAt;

  Map<String, dynamic> ToMap() => {
        'bulletToken': BulletToken,
        'gToken': GToken,
        'language': Language,
        'country': Country,
        'userAgent': UserAgent,
        'expiresAt': ExpiresAt,
      };

  static NSOToken FromMap(Map<String, dynamic> Data) => NSOToken(
        BulletToken: '${Data['bulletToken'] ?? ''}',
        GToken: '${Data['gToken'] ?? ''}',
        Language: '${Data['language'] ?? 'zh-CN'}',
        Country: '${Data['country'] ?? 'CN'}',
        UserAgent: '${Data['userAgent'] ?? ''}',
        ExpiresAt: Data['expiresAt'] is num ? (Data['expiresAt'] as num).toInt() : 0,
      );

  bool Expired([int Margin = 60000]) => DateTime.now().millisecondsSinceEpoch > ExpiresAt - Margin;
}

class AppStatus {
  AppStatus({
    required this.RecordState,
    required this.RecordError,
    required this.Width,
    required this.Height,
    required this.Fps,
    required this.Format,
    required this.PixelFormat,
    required this.Encoder,
    required this.HasAudio,
    required this.Audio,
    required this.AudioSource,
    required this.Segments,
    required this.CacheStart,
    required this.CacheEnd,
    required this.NSOState,
    required this.NSOError,
    required this.NSOAccounts,
    required this.NSOCurrentId,
    required this.NSOCurrentNickname,
    required this.QQState,
    required this.QQOwner,
    required this.QrCode,
    required this.SetupDone,
    required this.RecentMatches,
    required this.LatestMatch,
    required this.Settings,
    required this.RtmpState,
    required this.RtmpError,
    required this.RtmpWidth,
    required this.RtmpHeight,
    required this.RtmpFps,
    required this.RtmpPushState,
    required this.RtmpPushMode,
    required this.RtmpPushError,
    required this.HwAccel,
    required this.StreamEncoder,
    required this.StreamFormat,
    required this.RtmpInputUrl,
    required this.RtmpServerUrl,
    required this.PushState,
    required this.PushError,
    required this.Processing,
    required this.Devices,
    required this.Country,
    required this.PlatformName,
    required this.PlatformVersion,
  });

  String RecordState;
  String? RecordError;
  int Width;
  int Height;
  int Fps;
  String Format;
  String PixelFormat;
  String Encoder;
  bool HasAudio;
  String? Audio;
  String? AudioSource;
  int Segments;
  int? CacheStart;
  int? CacheEnd;
  String NSOState;
  String? NSOError;
  List<NSOAccount> NSOAccounts;
  String? NSOCurrentId;
  String? NSOCurrentNickname;
  String QQState;
  String? QQOwner;
  String? QrCode;
  bool SetupDone;
  List<BattleMatch> RecentMatches;
  BattleMatch? LatestMatch;
  RecordSettings Settings;
  String RtmpState;
  String? RtmpError;
  int RtmpWidth;
  int RtmpHeight;
  int RtmpFps;
  String RtmpPushState;
  String? RtmpPushMode;
  String? RtmpPushError;
  String? HwAccel;
  String? StreamEncoder;
  String? StreamFormat;
  String? RtmpInputUrl;
  String? RtmpServerUrl;
  String? PushState;
  String? PushError;
  Set<String> Processing;
  List<CaptureDevice> Devices;
  String Country;
  String PlatformName;
  String PlatformVersion;

  AppStatus Copy([Map<String, dynamic>? Part]) {
    if (Part == null) return this;
    return AppStatus(
      RecordState: Part['RecordState'] as String? ?? RecordState,
      RecordError: Part.containsKey('RecordError') ? Part['RecordError'] as String? : RecordError,
      Width: Part['Width'] as int? ?? Width,
      Height: Part['Height'] as int? ?? Height,
      Fps: Part['Fps'] as int? ?? Fps,
      Format: Part['Format'] as String? ?? Format,
      PixelFormat: Part['PixelFormat'] as String? ?? PixelFormat,
      Encoder: Part['Encoder'] as String? ?? Encoder,
      HasAudio: Part['HasAudio'] as bool? ?? HasAudio,
      Audio: Part.containsKey('Audio') ? Part['Audio'] as String? : Audio,
      AudioSource: Part.containsKey('AudioSource') ? Part['AudioSource'] as String? : AudioSource,
      Segments: Part['Segments'] as int? ?? Segments,
      CacheStart: Part.containsKey('CacheStart') ? Part['CacheStart'] as int? : CacheStart,
      CacheEnd: Part.containsKey('CacheEnd') ? Part['CacheEnd'] as int? : CacheEnd,
      NSOState: Part['NSOState'] as String? ?? NSOState,
      NSOError: Part.containsKey('NSOError') ? Part['NSOError'] as String? : NSOError,
      NSOAccounts: Part['NSOAccounts'] as List<NSOAccount>? ?? NSOAccounts,
      NSOCurrentId: Part.containsKey('NSOCurrentId') ? Part['NSOCurrentId'] as String? : NSOCurrentId,
      NSOCurrentNickname: Part.containsKey('NSOCurrentNickname') ? Part['NSOCurrentNickname'] as String? : NSOCurrentNickname,
      QQState: Part['QQState'] as String? ?? QQState,
      QQOwner: Part.containsKey('QQOwner') ? Part['QQOwner'] as String? : QQOwner,
      QrCode: Part.containsKey('QrCode') ? Part['QrCode'] as String? : QrCode,
      SetupDone: Part['SetupDone'] as bool? ?? SetupDone,
      RecentMatches: Part['RecentMatches'] as List<BattleMatch>? ?? RecentMatches,
      LatestMatch: Part.containsKey('LatestMatch') ? Part['LatestMatch'] as BattleMatch? : LatestMatch,
      Settings: Part['Settings'] as RecordSettings? ?? Settings,
      RtmpState: Part['RtmpState'] as String? ?? RtmpState,
      RtmpError: Part.containsKey('RtmpError') ? Part['RtmpError'] as String? : RtmpError,
      RtmpWidth: Part['RtmpWidth'] as int? ?? RtmpWidth,
      RtmpHeight: Part['RtmpHeight'] as int? ?? RtmpHeight,
      RtmpFps: Part['RtmpFps'] as int? ?? RtmpFps,
      RtmpPushState: Part['RtmpPushState'] as String? ?? RtmpPushState,
      RtmpPushMode: Part.containsKey('RtmpPushMode') ? Part['RtmpPushMode'] as String? : RtmpPushMode,
      RtmpPushError: Part.containsKey('RtmpPushError') ? Part['RtmpPushError'] as String? : RtmpPushError,
      HwAccel: Part.containsKey('HwAccel') ? Part['HwAccel'] as String? : HwAccel,
      StreamEncoder: Part.containsKey('StreamEncoder') ? Part['StreamEncoder'] as String? : StreamEncoder,
      StreamFormat: Part.containsKey('StreamFormat') ? Part['StreamFormat'] as String? : StreamFormat,
      RtmpInputUrl: Part.containsKey('RtmpInputUrl') ? Part['RtmpInputUrl'] as String? : RtmpInputUrl,
      RtmpServerUrl: Part.containsKey('RtmpServerUrl') ? Part['RtmpServerUrl'] as String? : RtmpServerUrl,
      PushState: Part.containsKey('PushState') ? Part['PushState'] as String? : PushState,
      PushError: Part.containsKey('PushError') ? Part['PushError'] as String? : PushError,
      Processing: Part['Processing'] as Set<String>? ?? Processing,
      Devices: Part['Devices'] as List<CaptureDevice>? ?? Devices,
      Country: Part['Country'] as String? ?? Country,
      PlatformName: Part['PlatformName'] as String? ?? PlatformName,
      PlatformVersion: Part['PlatformVersion'] as String? ?? PlatformVersion,
    );
  }
}

class AppDirectories {
  AppDirectories({required this.Root});

  final String Root;

  String get Cache => '$Root${Platform.pathSeparator}cache';
  String get Temp => '$Cache${Platform.pathSeparator}tmp';
  String get Videos => '$Root${Platform.pathSeparator}videos';
  String get Matches => '$Root${Platform.pathSeparator}matches';
  String get Thumbs => '$Root${Platform.pathSeparator}thumbs';
  String get NSO => '$Root${Platform.pathSeparator}nso';
  String get QQ => '$Root${Platform.pathSeparator}qq';
  String get Logs => '$Root${Platform.pathSeparator}logs';
  String get Backgrounds => '$Root${Platform.pathSeparator}backgrounds';
  String get Backup => '$Root${Platform.pathSeparator}Backup';
  String get Update => '$Root${Platform.pathSeparator}update';
  String get ConfigFile => '$Root${Platform.pathSeparator}config.json';
  String get SecretFile => '$Root${Platform.pathSeparator}secrets.json';

  Future<void> Create() async {
    for (final Path in [Root, Cache, Temp, Videos, Matches, Thumbs, NSO, QQ, Logs, Backgrounds, Update]) {
      await Directory(Path).create(recursive: true);
    }
  }
}

String SafeJson(Object? Value) => jsonEncode(Value);
















