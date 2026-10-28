part of 'package:splatoon3record/app/controller.dart';

extension AppUpdateFlow on AppController {
  Future<UpdateInfo> UpdateCheck() async {
    final Match = RegExp(r'github[.]com[/:]([^/]+)/([^/#?]+)').firstMatch(Env.ProjectUrl);
    if (Match == null) throw StateError('未配置项目仓库地址');
    final Owner = Match.group(1);
    final Repo = Match.group(2)!.replaceFirst(RegExp(r'[.]git$'), '');
    final Target = 'https://api.github.com/repos/$Owner/$Repo/releases/latest';
    final Urls = SettingsValue.UpdateProxy
        ? <String>['${Env.UpdateProxyPrefix}$Target', Target]
        : <String>[Target, '${Env.UpdateProxyPrefix}$Target'];
    Object? Last;
    for (final Url in Urls) {
      try {
        final Response = await http.get(Uri.parse(Url), headers: <String, String>{'Accept': 'application/vnd.github+json', 'User-Agent': Env.UserAgent}).timeout(const Duration(seconds: 20));
        if (Response.statusCode != 200) throw StateError('获取更新失败：HTTP ${Response.statusCode}');
        final Data = jsonDecode(Response.body) as Map<String, dynamic>;
        final Latest = '${Data['tag_name'] ?? ''}'.replaceFirst(RegExp(r'^v', caseSensitive: false), '');
        final Notes = Data['body'] is String ? Data['body'] as String : '';
        if (!IsNewer(Version, Latest)) return const UpdateInfo();
        final Assets = Data['assets'] is List ? Data['assets'] as List : const <dynamic>[];
        Map? Pick;
        for (final Asset in Assets) {
          if (Asset is! Map) continue;
          final Name = '${Asset['name'] ?? ''}'.toLowerCase();
          final MatchAsset = Platform.isWindows
              ? RegExp(r'[.]exe$').hasMatch(Name)
              : Platform.isMacOS
                  ? RegExp(r'[.]dmg$').hasMatch(Name)
                  : RegExp(r'[.]appimage$|[.]tar[.]gz$').hasMatch(Name);
          if (MatchAsset) {
            Pick = Asset;
            break;
          }
        }
        if (Pick == null) return UpdateInfo(Tag: Latest, Notes: Notes);
        return UpdateInfo(
          Tag: Latest,
          Notes: Notes,
          Url: '${Pick['browser_download_url'] ?? ''}',
          Name: '${Pick['name'] ?? 'Update'}',
          Size: Pick['size'] is num ? (Pick['size'] as num).toInt() : 0,
        );
      } catch (Cause) {
        Last = Cause;
      }
    }
    throw StateError('$Last');
  }

  Future<String> DownloadUpdate(UpdateInfo Info, void Function(double Progress, int Received, int Total) OnProgress) async {
    final Name = Info.Name.isEmpty ? 'Splatoon3RecordUpdate.exe' : Info.Name;
    final Target = '${Directories.Update}${Platform.pathSeparator}$Name';
    final Part = '$Target.part';
    final Client = http.Client();
    try {
      final Request = http.Request('GET', Uri.parse(SettingsValue.UpdateProxy ? '${Env.UpdateProxyPrefix}${Info.Url}' : Info.Url));
      Request.headers['User-Agent'] = Env.UserAgent;
      final Response = await Client.send(Request);
      if (Response.statusCode != 200) throw StateError('下载更新失败：HTTP ${Response.statusCode}');
      final Total = Response.contentLength ?? Info.Size;
      final Sink = File(Part).openWrite();
      var Received = 0;
      await for (final Chunk in Response.stream) {
        Sink.add(Chunk);
        Received += Chunk.length;
        OnProgress(Total <= 0 ? 0 : Received / Total, Received, Total);
      }
      await Sink.flush();
      await Sink.close();
      final FileRef = File(Target);
      if (FileRef.existsSync()) await FileRef.delete();
      await File(Part).rename(Target);
      return Target;
    } finally {
      Client.close();
    }
  }

  Future<void> InstallUpdate(String Path) async {
    await Shutdown();
    if (Platform.isWindows) {
      await Process.start(Path, const <String>['/SILENT', '/CLOSEAPPLICATIONS', '/NORESTART'], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.start('open', <String>[Path], mode: ProcessStartMode.detached);
    } else {
      await Process.run('chmod', <String>['755', Path]);
      await Process.start(Path, const <String>[], mode: ProcessStartMode.detached);
    }
    exit(0);
  }

  bool IsNewer(String Current, String Candidate) {
    final Left = Current.split('.').map((Item) => int.tryParse(Item) ?? 0).toList();
    final Right = Candidate.split('.').map((Item) => int.tryParse(Item) ?? 0).toList();
    for (var Index = 0; Index < Left.length || Index < Right.length; Index++) {
      final A = Index < Left.length ? Left[Index] : 0;
      final B = Index < Right.length ? Right[Index] : 0;
      if (A != B) return B > A;
    }
    return false;
  }

}








