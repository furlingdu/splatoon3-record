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
    final Range = CacheRange(Refresh: true);
    final Start = Range.$2;
    final End = Range.$3;
    return Start != null && End != null && Match.EndAt >= Start && Match.EndAt <= End;
  }

  Future<bool> ArchiveMatch(BattleMatch Match) async {
    if (Match.HasVideo) return true;
    final Owned = Archiving.add(Match.Key);
    if (Owned) PushStatus();
    try {
      final Name = Formats.MatchFileName(Match.Kind, Match.EndAt, Match.Key);
      final Output = '${Directories.Videos}${Platform.pathSeparator}$Name.mp4';
      final Path = await Capture.Crop(Match, Output, SettingsValue, LeadMs: Match.Kind == 'highlight' ? 0 : Config.ClipLeadMs, TailMs: Match.Kind == 'highlight' ? 0 : Config.ClipTailMs);
      if (Path == null || !File(Path).existsSync() || File(Path).lengthSync() == 0) return false;
      Match.VideoPath = Path;
      await Archive.Save(Match);
      await FFmpeg.Thumbnail(Path, '${Directories.Thumbs}${Platform.pathSeparator}${Archive.SafeName(Match.Key)}.jpg');
      final Owner = Configs.Current.QQOwner;
      if (Match.Kind != 'highlight' && Configs.Current.PushEnabled && Owner != null && QQBotRef != null) {
        try {
          await QQBotRef!.SendVideo(Owner, Path);
          await QQBotRef!.SendMarkdown(Owner, QQMatchText(Match));
        } catch (_) {}
      }
      return true;
    } finally {
      if (Owned) {
        Archiving.remove(Match.Key);
        PushStatus();
      }
    }
  }

  void ScheduleArchive(BattleMatch Match) {
    if (Match.HasVideo || Match.SkipReason != null) return;
    if (!Archiving.add(Match.Key)) return;
    PushStatus();
    ArchiveTask = ArchiveTask.then((_) async {
      try {
        await WaitAndArchive(Match);
      } catch (Cause) {
        await Logs.App('archive failed ${Match.Key} $Cause');
      } finally {
        Archiving.remove(Match.Key);
        PushStatus();
      }
    });
  }

  Future<void> WaitAndArchive(BattleMatch Match) async {
    final Deadline = DateTime.now().add(const Duration(minutes: 3));
    while (!Match.HasVideo && Match.SkipReason == null) {
      final Range = CacheRange(Refresh: true);
      final Start = Range.$2;
      final End = Range.$3;
      if (Start != null && End != null) {
        if (Match.EndAt < Start || Match.EndAt + Config.ClipTailMs <= End) break;
        if (!Capture.Running && !Capture.Starting) break;
      } else if (!Capture.Running && !Capture.Starting) {
        break;
      }
      if (DateTime.now().isAfter(Deadline)) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (Match.HasVideo || Match.SkipReason != null) return;
    if (CanCrop(Match)) await ArchiveMatch(Match);
  }

  Future<void> ArchiveCached() async {
    final Records = await Capture.Records();
    if (Records.isEmpty) return;
    final Start = Records.first.StartAt;
    final End = Records.last.EndAt;
    final Pending = Archive.Matches.where((Match) => !Match.HasVideo && Match.SkipReason == null && Match.Kind != 'highlight' && MatchFilter.ShouldRecord(Match, SettingsValue) && Match.EndAt >= Start && Match.EndAt <= End).toList()
      ..sort((Left, Right) => Left.EndAt.compareTo(Right.EndAt));
    for (final Match in Pending) {
      ScheduleArchive(Match);
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
