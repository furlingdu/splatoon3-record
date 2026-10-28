part of 'package:splatoon3record/app/AppController.dart';

extension AppPlatformFlow on AppController {
  Future<void> MigrateHandled() async {    final Source = Configs.Current.HandledIds;
    final List<String> Result = <String>[];
    var Changed = false;
    for (final Id in Source) {
      var Next = Id;
      if (Next.startsWith('legacy:')) {
        Next = Next.substring(7);
        Changed = true;
      }
      if (!Next.contains(':')) {
        BattleMatch? Match;
        for (final Item in Archive.Matches) {
          if (Item.MatchId == Next) {
            Match = Item;
            break;
          }
        }
        if (Match != null && Match.AccountId != null) {
          Next = '${Match.AccountId}:${Match.MatchId}';
          Changed = true;
        }
      }
      if (!Result.contains(Next)) Result.add(Next);
    }
    final Limited = Result.length > 200 ? Result.sublist(Result.length - 200) : Result;
    if (Changed || Limited.length != Source.length) {
      await Configs.Save(AppConfig(Settings: Configs.Current.Settings, PushEnabled: Configs.Current.PushEnabled, SetupDone: Configs.Current.SetupDone, QQOwner: Configs.Current.QQOwner, HandledIds: Limited, Raw: Configs.Current.Raw));
    }
  }

  Future<void> FinishSetup() async {
    if (PlatformInfo.Mobile && !MobileSetupReady) {
      Notice = '请先完成 Nintendo 账号和 QQBot 登录';
      Notify();
      return;
    }
    if (!QQReady) {
      Notice = '请在机器人私聊窗口发送 /bind 完成 QQBot 绑定';
      Notify();
      return;
    }
    final Next = AppConfig(
      Settings: SettingsValue,
      PushEnabled: Configs.Current.PushEnabled,
      SetupDone: true,
      QQOwner: Configs.Current.QQOwner,
      HandledIds: Configs.Current.HandledIds,
      Raw: Configs.Current.Raw,
    );
    await Configs.Save(Next);
    Page = 'status';
    PushStatus();
    if (SettingsValue.AutoRecord && PlatformInfo.Desktop) await StartRecord();
    if (PlatformInfo.Desktop) unawaited(WarmPreviewWindow());
  }

  Future<void> PickFolder() async {
    final Path = await getDirectoryPath(confirmButtonText: '选择文件夹');
    if (Path == null) return;
    await SaveSettings(SettingsValue.Copy(<String, dynamic>{'saveDir': Path}));
  }

  Future<void> PickBackground() async {
    try {
      String? SourcePath;
      if (PlatformInfo.Mobile) {
        final Picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 95);
        SourcePath = Picked?.path;
      } else {
        await windowManager.focus();
        final Type = const XTypeGroup(label: '图片', extensions: <String>['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp']);
        final FileRef = await openFile(acceptedTypeGroups: <XTypeGroup>[Type], confirmButtonText: '选择背景图片');
        SourcePath = FileRef?.path;
      }
      if (SourcePath == null) return;
      final Info = await File(SourcePath).stat();
      if (Info.size > 20 * 1024 * 1024) {
        Notice = '背景图片超过 20MB 或无法读取';
        Notify();
        return;
      }
      await Directory(Directories.Backgrounds).create(recursive: true);
      final Ext = SourcePath.contains('.') ? SourcePath.substring(SourcePath.lastIndexOf('.')) : '.png';
      final Target = '${Directories.Backgrounds}${Platform.pathSeparator}background-${DateTime.now().millisecondsSinceEpoch}$Ext';
      await File(SourcePath).copy(Target);
      await SaveSettings(SettingsValue.Copy(<String, dynamic>{'backgroundPath': Target}));
    } catch (Cause) {
      Notice = '选择背景图片失败：$Cause';
      Notify();
    }
  }

  Future<void> ResetBackground() async {
    await SaveSettings(SettingsValue.Copy(<String, dynamic>{'backgroundPath': ''}));
  }

  Future<void> OpenPath(String Value) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', <String>['/select,${Value}']);
      } else if (Platform.isMacOS) {
        await Process.run('open', <String>['-R', Value]);
      } else {
        await Process.run('xdg-open', <String>[File(Value).parent.path]);
      }
    } catch (_) {}
  }

  Future<void> OpenFile(String Value) async {
    if (Platform.isWindows) {
      await Process.start('cmd', <String>['/c', 'start', '', Value], runInShell: true);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[Value]);
    } else {
      await Process.run('xdg-open', <String>[Value]);
    }
  }

  Future<void> ApplyAutoLaunch() async {
    try {
      const Name = 'Splatoon3Record';
      if (Platform.isWindows) {
        final Key = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run';
        if (SettingsValue.AutoLaunch) {
          await Process.run('reg', <String>['add', Key, '/v', Name, '/t', 'REG_SZ', '/d', Platform.resolvedExecutable, '/f']);
        } else {
          await Process.run('reg', <String>['delete', Key, '/v', Name, '/f']);
        }
      }
    } catch (_) {}
  }

  Future<void> RegisterProtocol() async {
    if (!Platform.isWindows) return;
    try {
      final Key = 'HKCU\\Software\\Classes\\npf${Config.NSOClientId}';
      final Exe = Platform.resolvedExecutable;
      await Process.run('reg', <String>['add', Key, '/ve', '/d', 'URL:Nintendo Switch Online', '/f']);
      await Process.run('reg', <String>['add', Key, '/v', 'URL Protocol', '/d', '', '/f']);
      await Process.run('reg', <String>['add', '$Key\\shell\\open\\command', '/ve', '/d', '"$Exe" "%1"', '/f']);
    } catch (_) {}
  }

  Future<void> Relaunch() async {
    await Shutdown();
    await Process.start(Platform.resolvedExecutable, const <String>[], mode: ProcessStartMode.detached);
    exit(0);
  }

  Future<void> ClosePreviewWindow() async {
    try {
      final Client = await Socket.connect(InternetAddress.loopbackIPv4, Config.PreviewInstancePort, timeout: const Duration(milliseconds: 300));
      Client.write('QUIT');
      await Client.flush();
      await Client.close();
    } catch (_) {}
  }

  Future<void> Shutdown() async {
    await ClosePreviewWindow();
    await StopPreview();
    await Capture.Stop(Fast: true);
    await QQBindRef?.Stop();
    await QQBotRef?.Stop();
    await Logs.App('app exit');
  }

}









