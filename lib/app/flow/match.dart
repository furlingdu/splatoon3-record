part of 'package:splatoon3record/app/controller.dart';

extension AppMatchFlow on AppController {

  Future<void> RefreshMatches() async {
    await Archive.Load();
    PushStatus();
  }

  Future<void> DeleteMatch(BattleMatch Match, bool WithBlur) async {
    await Archive.Delete(Match, WithBlur);
    PushStatus();
  }

  Future<bool> BlurMatch(BattleMatch Match) async {
    if (!Match.HasVideo) return false;
    final Output = Archive.BlurFile(Match.VideoPath);
    if (Output == null) return false;
    final Path = await Blur.Blur(Match.VideoPath!, Output);
    if (Path == null) return false;
    Match.BlurCopy = true;
    await Archive.Save(Match);
    PushStatus();
    return true;
  }

  Future<void> SaveMatchVideo(BattleMatch Match) async {
    if (!Match.HasVideo) return;
    final Target = await getSaveLocation(suggestedName: '${Match.MatchId}.mp4');
    if (Target == null) return;
    await File(Match.VideoPath!).copy(Target.path);
  }

  bool CanCrop(BattleMatch Match) {
    if (Match.HasVideo) return false;
    final Start = Status?.CacheStart;
    final End = Status?.CacheEnd;
    return Start != null && End != null && Match.EndAt >= Start && Match.EndAt <= End;
  }

  Future<bool> ArchiveMatch(BattleMatch Match) async {
    final Name = Formats.MatchFileName(Match.Kind, Match.EndAt, Match.Key);
    final Output = '${Directories.Videos}${Platform.pathSeparator}$Name.mp4';
    final Path = await Capture.Crop(Match, Output, SettingsValue);
    if (Path == null || !File(Path).existsSync() || File(Path).lengthSync() == 0) return false;
    Match.VideoPath = Path;
    await Archive.Save(Match);
    await FFmpeg.Thumbnail(Path, '${Directories.Thumbs}${Platform.pathSeparator}${Archive.SafeName(Match.Key)}.jpg');
    final Owner = Configs.Current.QQOwner;
    if (Configs.Current.PushEnabled && Owner != null && QQBotRef != null) {
      try {
        await QQBotRef!.SendVideo(Owner, Path);
        await QQBotRef!.SendMarkdown(Owner, QQMatchText(Match));
      } catch (_) {}
    }
    PushStatus();
    return true;
  }

  Future<void> ArchiveCached() async {
    final Records = await Capture.Records();
    if (Records.isEmpty) return;
    final Start = Records.first.StartAt;
    final End = Records.last.EndAt;
    for (final Match in Archive.Matches) {
      if (Match.HasVideo || Match.SkipReason != null) continue;
      if (Match.EndAt < Start || Match.EndAt > End) continue;
      await ArchiveMatch(Match);
    }
  }



  Future<void> GenerateThumbs() async {
    for (final Match in List<BattleMatch>.of(Archive.Matches)) {
      if (!Match.HasVideo) continue;
      final Path = '${Directories.Thumbs}${Platform.pathSeparator}${Archive.SafeName(Match.Key)}.jpg';
      if (File(Path).existsSync()) continue;
      final Ok = await FFmpeg.Thumbnail(Match.VideoPath!, Path);
      if (Ok) Notify();
    }
  }

}








