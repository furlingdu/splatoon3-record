import 'dart:convert';
import 'dart:io';

import '../config/constants.dart';

import '../domain/models.dart';

class PathStore {
  PathStore._();

  static String? MobileRoot;

  static AppDirectories Open() {
    final Override = Platform.environment['SPLATOON3RECORD_HOME'];
    if (Override != null && Override.isNotEmpty) {
      return AppDirectories(Root: Override);
    }
    final Sandbox = MobileRoot;
    if (Sandbox != null && Sandbox.isNotEmpty) {
      return AppDirectories(Root: Sandbox);
    }
    final Home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.current.path;
    return AppDirectories(Root: '$Home${Platform.pathSeparator}.splatoon3record');
  }
}

class EnvStore {
  EnvStore(this.Directories) {
    Load();
  }

  final AppDirectories Directories;
  final Map<String, String> Values = <String, String>{};

  void Load() {
    final Candidates = <String>[
      '${Directory.current.path}${Platform.pathSeparator}.env',
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}.env',
      '${Directories.Root}${Platform.pathSeparator}.env',
    ];
    for (final Path in Candidates) {
      final FileRef = File(Path);
      if (!FileRef.existsSync()) continue;
      try {
        for (final Line in FileRef.readAsLinesSync()) {
          final Trimmed = Line.trim();
          if (Trimmed.isEmpty || Trimmed.startsWith('#')) continue;
          final Index = Trimmed.indexOf('=');
          if (Index <= 0) continue;
          final Key = Trimmed.substring(0, Index).trim();
          var Value = Trimmed.substring(Index + 1).trim();
          if ((Value.startsWith('"') && Value.endsWith('"')) || (Value.startsWith("'") && Value.endsWith("'"))) {
            Value = Value.substring(1, Value.length - 1);
          }
          Values.putIfAbsent(Key, () => Value);
        }
      } catch (_) {
        continue;
      }
      break;
    }
  }

  String Get(String Key, String Fallback) {
    final Value = Values[Key];
    return Value == null || Value.isEmpty ? Fallback : Value;
  }

  String get AppName => Get('APP_NAME', 'Splatoon3 Record');
  String get ProjectName => Get('PROJECT_NAME', 'Splatoon3Record');
  String get ProjectUrl => Get('PROJECT_URL', 'https://github.com/furlingdu/splatoon3-record');
  String get ProjectVersion => Get('PROJECT_VERSION', Config.AppVersion);
  String get AuthorAvatar => Get('AUTHOR_AVATAR_URL', 'https://q2.qlogo.cn/headimg_dl?dst_uin=3648192311&spec=640');
  String get NSOBackend => Get('NSO_BACKEND_URL', 'https://znca.furlingdu.com');
  String get UpdateProxyPrefix => Get('UPDATE_PROXY_PREFIX', 'https://gh-proxy.com/');
  String get UserAgent => '${ProjectName}/${ProjectVersion} (+${ProjectUrl})';
  String get PushCodec => Get('PUSH_CODEC', 'hevc');
  double get PushBitrate {
    final Value = double.tryParse(Get('PUSH_BITRATE_MBPS', '2')) ?? 2;
    return Value.clamp(0.1, 50).toDouble();
  }

  int get PushLimit {
    final Value = int.tryParse(Get('PUSH_FILE_LIMIT_MB', '100')) ?? 100;
    return Value.clamp(1, 100);
  }
}

class ConfigStore {
  ConfigStore(this.Directories, this.Env);

  final AppDirectories Directories;
  final EnvStore Env;
  AppConfig Current = AppConfig.Defaults();
  Future<void> _Saving = Future<void>.value();

  Future<AppConfig> Load() async {
    await Directories.Create();
    await Backup();
    final FileRef = File(Directories.ConfigFile);
    if (!FileRef.existsSync()) {
      Current = AppConfig.Defaults(RecordSettings(SaveDir: Directories.Videos));
      await Save(Current);
      return Current;
    }
    try {
      final Data = jsonDecode(await FileRef.readAsString());
      if (Data is Map<String, dynamic>) {
        Current = AppConfig.FromMap(Data);
        if (Current.Settings.SaveDir.isEmpty) {
          Current.Settings.SaveDir = Directories.Videos;
        }
        Current.HandledIds = NormalizeHandled(Current.HandledIds);
        await Save(Current);
        return Current;
      }
    } catch (_) {
      final Broken = File('${Directories.ConfigFile}.broken');
      try {
        await FileRef.copy(Broken.path);
      } catch (_) {}
    }
    Current = AppConfig.Defaults(RecordSettings(SaveDir: Directories.Videos));
    await Save(Current);
    return Current;
  }

  Future<void> Backup() async {
    try {
      final Marker = File('${Directories.Backup}${Platform.pathSeparator}Migrated');
      if (Marker.existsSync()) return;
      final Stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final Folder = Directory('${Directories.Backup}${Platform.pathSeparator}$Stamp');
      await Folder.create(recursive: true);
      for (final Source in <String>[Directories.ConfigFile, Directories.SecretFile]) {
        final FileRef = File(Source);
        if (FileRef.existsSync()) await FileRef.copy('${Folder.path}${Platform.pathSeparator}${FileRef.uri.pathSegments.last}');
      }
      for (final Name in <String>['matches', 'thumbs', 'backgrounds']) {
        final Source = Directory('${Directories.Root}${Platform.pathSeparator}$Name');
        if (!Source.existsSync()) continue;
        final Target = Directory('${Folder.path}${Platform.pathSeparator}$Name');
        await Target.create(recursive: true);
        await for (final Item in Source.list(recursive: true)) {
          if (Item is! File) continue;
          final Relative = Item.path.substring(Source.path.length + 1);
          final Output = File('${Target.path}${Platform.pathSeparator}$Relative');
          await Output.parent.create(recursive: true);
          await Item.copy(Output.path);
        }
      }
      await Marker.writeAsString(Stamp);
    } catch (_) {}
  }

  List<String> NormalizeHandled(List<String> Ids) {
    final List<String> Result = <String>[];
    for (final Id in Ids) {
      final Normalized = Id.startsWith('legacy:') ? Id.substring(7) : Id;
      if (!Result.contains(Normalized)) Result.add(Normalized);
    }
    return Result.length > 200 ? Result.sublist(Result.length - 200) : Result;
  }

  Future<void> Save(AppConfig Value) {
    Current = Value;
    final Text = const JsonEncoder.withIndent('  ').convert(Value.ToMap());
    final Task = _Saving.then((_) async {
      final Target = File(Directories.ConfigFile);
      final Temp = File('${Target.path}.tmp');
      await Temp.writeAsString(Text, flush: true);
      await Temp.rename(Target.path);
    });
    _Saving = Task.catchError((_) {});
    return Task;
  }

  Future<AppConfig> SaveSettings(RecordSettings Value) async {
    final Next = AppConfig(
      Settings: Value,
      PushEnabled: Value.AutoPush,
      SetupDone: Current.SetupDone,
      QQOwner: Current.QQOwner,
      HandledIds: Current.HandledIds,
      Raw: Current.Raw,
    );
    await Save(Next);
    return Next;
  }
}

class LogStore {
  LogStore(this.Directories);

  final AppDirectories Directories;

  final Map<String, Future<void>> Writes = <String, Future<void>>{};

  Future<void> Write(String Name, String Message) {
    final Path = '${Directories.Logs}${Platform.pathSeparator}$Name.log';
    final Previous = Writes[Name] ?? Future<void>.value();
    final Next = Previous.then((_) async {
      try {
        await Directory(Directories.Logs).create(recursive: true);
        await File(Path).writeAsString('${DateTime.now().toIso8601String()} $Message\n', mode: FileMode.append, flush: true);
      } catch (_) {}
    });
    Writes[Name] = Next;
    return Next;
  }

  Future<void> App(String Message) => Write('app', Message);

  Future<void> Capture(String Message) => Write('capture', Message);

  Future<void> Login(String Message) => Write('loginDebug', Message);

  Future<String?> Report(String Text) async {
    try {
      await Directory(Directories.Logs).create(recursive: true);
      final Now = DateTime.now();
      String Pad(int Value) => Value.toString().padLeft(2, '0');
      final Name = 'report-${Now.year}${Pad(Now.month)}${Pad(Now.day)}-${Pad(Now.hour)}${Pad(Now.minute)}${Pad(Now.second)}.txt';
      final Path = '${Directories.Logs}${Platform.pathSeparator}$Name';
      final Lines = <String>[Text, '', '===== 运行日志 =====', '日志目录：${Directories.Logs}', '生成时间：${Now.toIso8601String()}'];
      for (final FileName in ['app.log', 'capture.log', 'loginDebug.log']) {
        final LogFile = File('${Directories.Logs}${Platform.pathSeparator}$FileName');
        Lines.add('');
        Lines.add('===== $FileName =====');
        if (LogFile.existsSync()) {
          final All = LogFile.readAsLinesSync();
          final Kept = All.length > 400 ? All.sublist(All.length - 400) : All;
          Lines.add('行数：${All.length}${All.length > Kept.length ? '（仅保留最后 ${Kept.length} 行）' : ''}');
          Lines.add('大小：${LogFile.lengthSync()} 字节');
          Lines.add('修改时间：${LogFile.lastModifiedSync().toIso8601String()}');
          Lines.addAll(Kept);
        } else {
          Lines.add('（无日志文件）');
        }
      }
      await File(Path).writeAsString(Redact(Lines.join('\n')));
      return Path;
    } catch (_) {
      return null;
    }
  }

  String Redact(String Text) {
    var Result = Text;
    for (final Key in ['session_token_code', 'access_token', 'id_token', 'refresh_token', 'code_verifier', 'code_challenge', 'bulletToken', 'gToken']) {
      Result = Result.replaceAll(RegExp('("?$Key"?\\s*[:=]\\s*)("[^"]*"|[^\\s,}]+)', caseSensitive: false), r'$1***');
    }
    Result = Result.replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._-]+'), 'Bearer ***');
    return Result;
  }
}

class ArchiveStore {
  ArchiveStore(this.Directories);

  final AppDirectories Directories;
  List<BattleMatch> Matches = <BattleMatch>[];
  Future<void> _Saving = Future<void>.value();

  Future<List<BattleMatch>> Load() async {
    await Directory(Directories.Matches).create(recursive: true);
    final Result = <String, BattleMatch>{};
    final Entries = Directory(Directories.Matches).listSync();
    for (final Entry in Entries) {
      if (Entry is! File || !Entry.path.toLowerCase().endsWith('.json')) continue;
      try {
        final Data = jsonDecode(await Entry.readAsString());
        if (Data is! Map<String, dynamic>) continue;
        final Match = BattleMatch.FromMap(Data);
        if (Match.MatchId.isEmpty) continue;
        if (Match.VideoPath != null) {
          final Video = File(Match.VideoPath!);
          if (!Video.existsSync() || Video.lengthSync() == 0) Match.VideoPath = null;
        }
        final BlurPath = BlurFile(Match.VideoPath);
        Match.BlurCopy = BlurPath != null && File(BlurPath).existsSync();
        final Current = Result[Match.Key];
        if (Current == null || (Current.VideoPath == null && Match.VideoPath != null)) {
          Result[Match.Key] = Match;
        }
      } catch (_) {}
    }
    Matches = Result.values.toList()
      ..sort((Left, Right) => Right.EndAt.compareTo(Left.EndAt));
    return Matches;
  }

  Future<void> Save(BattleMatch Match) {
    final Data = Map<String, dynamic>.from(Match.ToMap());
    Data.remove('blurCopy');
    Data.remove('key');
    final Text = const JsonEncoder.withIndent('  ').convert(Data);
    final Target = File('${Directories.Matches}${Platform.pathSeparator}${SafeName('${Match.MatchId}-${Match.AccountId ?? ''}')}.json');
    final Task = _Saving.then((_) async {
      await Directory(Directories.Matches).create(recursive: true);
      final Temp = File('${Target.path}.tmp');
      await Temp.writeAsString(Text, flush: true);
      await Temp.rename(Target.path);
    });
    _Saving = Task.catchError((_) {});
    return Task.then((_) {
      final Index = Matches.indexWhere((Item) => Item.Key == Match.Key);
      if (Index >= 0) {
        Matches[Index] = Match;
      } else {
        Matches.insert(0, Match);
      }
      Matches.sort((Left, Right) => Right.EndAt.compareTo(Left.EndAt));
    });
  }

  Future<void> Delete(BattleMatch Match, bool WithBlur) async {
    final Base = '${Match.MatchId}-${Match.AccountId ?? ''}';
    for (final Name in <String>{SafeName(Base), LegacyName(Base), SafeName(Match.MatchId), LegacyName(Match.MatchId)}) {
      final FileRef = File('${Directories.Matches}${Platform.pathSeparator}$Name.json');
      if (FileRef.existsSync()) await FileRef.delete();
    }
    if (Match.VideoPath != null) {
      final Video = File(Match.VideoPath!);
      if (Video.existsSync()) await Video.delete();
      final Blur = BlurFile(Match.VideoPath);
      if (WithBlur && Blur != null && File(Blur).existsSync()) await File(Blur).delete();
    }
    Matches.removeWhere((Item) => Item.Key == Match.Key);
  }

  String? BlurFile(String? VideoPath) {
    if (VideoPath == null || VideoPath.isEmpty) return null;
    final Video = File(VideoPath);
    final Folder = '${Video.parent.path}${Platform.pathSeparator}blur';
    final Parts = VideoPath.split(Platform.pathSeparator);
    final Name = Parts.isEmpty ? VideoPath : Parts.last;
    final Stem = Name.replaceFirst(RegExp(r'\.mp4$', caseSensitive: false), '');
    return '$Folder${Platform.pathSeparator}$Stem-昵称打码.mp4';
  }

  String SafeName(String Value) {
    var Changed = false;
    final Buffer = StringBuffer();
    final Pattern = RegExp(r'[^a-zA-Z0-9]+([a-zA-Z0-9])?');
    var Last = 0;
    for (final Match in Pattern.allMatches(Value)) {
      Buffer.write(Value.substring(Last, Match.start));
      final Next = Match.group(1);
      if (Next != null && Next.isNotEmpty) Buffer.write(Next.toUpperCase());
      Last = Match.end;
      Changed = true;
    }
    Buffer.write(Value.substring(Last));
    var Base = Buffer.toString();
    if (Base.isEmpty) {
      Base = 'file';
      Changed = true;
    } else if (RegExp(r'^[0-9]').hasMatch(Base)) {
      Base = 'file$Base';
      Changed = true;
    } else {
      Base = Base[0].toLowerCase() + Base.substring(1);
      Changed = true;
    }
    if (!Changed && Base == Value) return Base;
    return '${Base}h${NameHash(Value)}';
  }

  String LegacyName(String Value) => Value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  String NameHash(String Value) {
    var Hash = 2166136261;
    for (final Byte in utf8.encode(Value)) {
      Hash ^= Byte;
      Hash = (Hash * 16777619) & 0xffffffff;
    }
    return Hash.toRadixString(16).padLeft(8, '0');
  }
}













