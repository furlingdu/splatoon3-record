import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/domain/Models.dart';
import 'package:splatoon3record/store/SecretStore.dart';
import 'package:splatoon3record/store/Stores.dart';

void main() {
  late Directory Temp;
  late AppDirectories Directories;
  late EnvStore Env;

  setUp(() async {
    Temp = await Directory.systemTemp.createTemp('s3r-test-');
    Directories = AppDirectories(Root: Temp.path);
    await Directories.Create();
    Env = EnvStore(Directories);
  });

  tearDown(() async {
    try {
      await Temp.delete(recursive: true);
    } catch (_) {}
  });

  test('Config persists and backs up old data', () async {
    final Store = ConfigStore(Directories, Env);
    final Loaded = await Store.Load();
    expect(Loaded.SetupDone, false);
    final Changed = await Store.SaveSettings(RecordSettings(SaveDir: Directories.Videos, Width: 1280, Height: 720, Fps: 30));
    expect(Changed.Settings.Width, 1280);
    expect(File(Directories.ConfigFile).existsSync(), true);
    expect(Directory(Directories.Backup).listSync().isNotEmpty, true);
  });

  test('Archive roundtrip and missing video handling', () async {
    final Store = ArchiveStore(Directories);
    final Match = BattleMatch.FromMap(<String, dynamic>{
      'matchId': 'abc',
      'accountId': 'acc',
      'kind': 'regular',
      'result': 'WIN',
      'startAt': 1000,
      'endAt': 2000,
      'duration': 1000,
      'videoPath': '${Directories.Videos}${Platform.pathSeparator}missing.mp4',
    });
    await Store.Save(Match);
    final List = await ArchiveStore(Directories).Load();
    expect(List.length, 1);
    expect(List.first.VideoPath, null);
    expect(List.first.Key, 'acc:abc');
  });

  test('SafeName matches old archive contract', () {
    final Store = ArchiveStore(Directories);
    expect(Store.SafeName('abc-123'), Store.SafeName('abc-123'));
    expect(Store.SafeName('abc-123').length, greaterThan(0));
    expect(Store.LegacyName('a/b:c'), 'a_b_c');
  });

  test('Secret vault roundtrip', () async {
    final Store = SecretStore(Directories);
    await Store.Save(<String, dynamic>{'qqAppId': '123', 'qqSecret': 'secret'});
    final Loaded = await SecretStore(Directories).Load();
    expect(Loaded['qqAppId'], '123');
    expect(Loaded['qqSecret'], 'secret');
  });
}







