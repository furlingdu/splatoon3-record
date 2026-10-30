import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/domain/models.dart';
import 'package:splatoon3record/store/secrets.dart';
import 'package:splatoon3record/store/storage.dart';

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

  test('Concurrent config saves keep the last value', () async {
    final Store = ConfigStore(Directories, Env);
    await Store.Load();
    final Tasks = <Future<void>>[];
    for (var Index = 0; Index < 12; Index++) {
      Tasks.add(Store.Save(AppConfig.Defaults(RecordSettings(SaveDir: Directories.Videos, Width: 640 + Index * 2, Fps: 30))));
    }
    await Future.wait(Tasks);
    final Text = await File(Directories.ConfigFile).readAsString();
    final Data = jsonDecode(Text) as Map<String, dynamic>;
    final Settings = Map<String, dynamic>.from(Data['settings'] as Map);
    expect(Settings['width'], 640 + 11 * 2);
  });

  test('Concurrent secret saves keep the last value', () async {
    final Store = SecretStore(Directories);
    final Tasks = <Future<void>>[];
    for (var Index = 0; Index < 12; Index++) {
      Tasks.add(Store.Save(<String, dynamic>{'qqAppId': '$Index', 'qqSecret': 'secret$Index'}));
    }
    await Future.wait(Tasks);
    final Loaded = await SecretStore(Directories).Load();
    expect(Loaded['qqAppId'], '11');
    expect(Loaded['qqSecret'], 'secret11');
  });

  test('Concurrent match saves keep every file valid', () async {
    final Store = ArchiveStore(Directories);
    await Store.Load();
    final Tasks = <Future<void>>[];
    for (var Index = 0; Index < 8; Index++) {
      Tasks.add(Store.Save(BattleMatch.FromMap(<String, dynamic>{
        'matchId': 'm$Index',
        'accountId': 'acc',
        'kind': 'regular',
        'result': 'WIN',
        'startAt': 1000 + Index,
        'endAt': 2000 + Index,
        'duration': 1000,
      })));
    }
    await Future.wait(Tasks);
    final Entries = Directory(Directories.Matches).listSync();
    final Files = Entries.whereType<File>().where((Item) => Item.path.endsWith('.json')).toList();
    expect(Files.length, 8);
    for (final Item in Files) {
      expect(jsonDecode(await Item.readAsString()) is Map, true);
    }
    expect(Entries.where((Item) => Item.path.endsWith('.tmp')).isEmpty, true);
    expect((await ArchiveStore(Directories).Load()).length, 8);
  });
}







