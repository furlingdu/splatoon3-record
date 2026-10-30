part of 'package:splatoon3record/app/controller.dart';

extension AppVisionFlow on AppController {
  bool get NeedVision => SettingsValue.RecordWork || SettingsValue.RecordHighlight || (SettingsValue.BlurNickname && Capture.LiveTarget != null);

  DetectionGate GateFor(int Label) {
    return Gates.putIfAbsent(Label, () {
      if (Label == Config.HighlightLabel) return DetectionGate(RequiredHits: 1, CooldownMs: Config.HighlightCooldownMs, ReleaseMs: 1500);
      if (Label == Config.WorkStartLabel) return DetectionGate(RequiredHits: 2, CooldownMs: 60000, ReleaseMs: 3000);
      if (Label == Config.WorkEndLabel || Label == Config.WorkResultLabel) return DetectionGate(RequiredHits: 2, CooldownMs: 120000, ReleaseMs: 3000);
      if (Label == Config.WipeoutLabel) return DetectionGate(RequiredHits: 2, CooldownMs: 10000, ReleaseMs: 2000);
      return DetectionGate(RequiredHits: 2, CooldownMs: 60000, ReleaseMs: 3000);
    });
  }

  Future<void> SyncVision() async {
    if (Capture.Running && NeedVision) {
      await StartVision();
    } else if (VisionRunning) {
      await StopVision();
    }
  }

  Future<void> StartVision() async {
    if (VisionRunning || VisionStarting) return;
    VisionStarting = true;
    VisionUnavailable = false;
    try {
      await Capture.SetVision(true);
      try {
        await Vision.Start();
      } catch (Cause) {
        VisionUnavailable = true;
        await Capture.SetVision(false);
        Notice = '画面识别启动失败：$Cause';
        await Logs.App('vision start failed $Cause');
        Notify();
        return;
      }
      if (!Capture.Running || !NeedVision) {
        await Vision.Stop();
        await Capture.SetVision(false);
        return;
      }
      VisionRunning = true;
      VisionClock?.cancel();
      VisionClock = Timer(Duration.zero, () => unawaited(VisionTick()));
      await Logs.App('vision start interval=${Config.DetectIntervalMs}ms work=${SettingsValue.RecordWork} highlight=${SettingsValue.RecordHighlight} blur=${SettingsValue.BlurNickname}');
    } finally {
      VisionStarting = false;
    }
  }

  Future<void> StopVision() async {
    if (!VisionRunning && VisionClock == null) return;
    VisionRunning = false;
    VisionClock?.cancel();
    VisionClock = null;
    await Capture.SetVision(false);
    try {
      await Vision.Stop();
    } catch (_) {}
    await Logs.App('vision stop');
  }

  Future<void> VisionTick() async {
    if (!VisionRunning || VisionBusy) return;
    VisionBusy = true;
    final RequestedAt = DateTime.now().millisecondsSinceEpoch;
    try {
      final Frame = await Capture.VisionSnapshot();
      if (Frame != null && VisionRunning) {
        final Boxes = await Vision.Detect(Frame.Rgba, Frame.Width, Frame.Height);
        if (VisionRunning) HandleBoxes(Boxes, RequestedAt);
      }
    } catch (Cause) {
      await Logs.App('vision tick failed $Cause');
    } finally {
      VisionBusy = false;
      if (VisionRunning) {
        VisionClock?.cancel();
        VisionClock = Timer(const Duration(milliseconds: Config.DetectIntervalMs), () => unawaited(VisionTick()));
      }
    }
  }

  void HandleBoxes(List<DetectedBox> Boxes, int At) {
    final Best = <int, double>{};
    for (final Box in Boxes) {
      final Current = Best[Box.Label] ?? 0;
      if (Box.Confidence > Current) Best[Box.Label] = Box.Confidence;
    }
    final Labels = <int>[Config.WipeoutLabel, Config.HighlightLabel, Config.WorkStartLabel, Config.WorkResultLabel, Config.WorkEndLabel];
    for (final Label in Labels) {
      if (Label == Config.HighlightLabel && !SettingsValue.RecordHighlight) continue;
      if ((Label == Config.WorkStartLabel || Label == Config.WorkResultLabel || Label == Config.WorkEndLabel) && !SettingsValue.RecordWork) continue;
      final Seen = (Best[Label] ?? 0) >= Config.EventConfidence;
      final TriggerAt = GateFor(Label).Update(At, Seen, Config.DetectIntervalMs);
      if (TriggerAt == null) continue;
      if (Label == Config.HighlightLabel) {
        unawaited(Logs.App('vision highlight at=$TriggerAt conf=${(Best[Label] ?? 0).toStringAsFixed(2)}'));
        unawaited(QueueHighlight(TriggerAt));
      } else if (Label == Config.WorkStartLabel) {
        Timeline.Add(WorkEventKind.start, TriggerAt, Best[Label] ?? 0);
        unawaited(Logs.App('vision work start at=$TriggerAt'));
      } else if (Label == Config.WorkEndLabel) {
        Timeline.Add(WorkEventKind.end, TriggerAt, Best[Label] ?? 0);
        unawaited(Logs.App('vision work end at=$TriggerAt'));
      } else if (Label == Config.WorkResultLabel) {
        Timeline.Add(WorkEventKind.result, TriggerAt, Best[Label] ?? 0);
        unawaited(Logs.App('vision work result at=$TriggerAt'));
      } else if (Label == Config.WipeoutLabel) {
        unawaited(Logs.App('vision wipeout at=$TriggerAt'));
      }
    }
    Timeline.Trim(At);
    if (SettingsValue.BlurNickname && Capture.LiveTarget != null) {
      final Mask = BuildMask(Boxes.where((Item) => (Item.Label == Config.PlayerNicknameLabel || Item.Label == Config.KillPlayerNicknameLabel) && Item.Confidence >= Config.NicknameConfidence).toList(), Config.MaskWidth, Config.MaskHeight);
      if (Capture is DesktopCaptureAdapter) (Capture as DesktopCaptureAdapter).Inner.UpdateMask(Mask);
    }
  }

  Future<Uint8List?> MaskFromFrame(Uint8List Rgba, int Width, int Height) async {
    if (VisionUnavailable) return null;
    try {
      final Boxes = await Vision.Detect(Rgba, Width, Height, Confidence: Config.NicknameConfidence);
      HandleBoxes(Boxes, DateTime.now().millisecondsSinceEpoch);
      return BuildMask(Boxes.where((Item) => Item.Label == Config.PlayerNicknameLabel || Item.Label == Config.KillPlayerNicknameLabel).toList(), Config.MaskWidth, Config.MaskHeight);
    } catch (_) {
      return null;
    }
  }

  Future<void> QueueHighlight(int At) async {
    if (!SettingsValue.RecordHighlight) return;
    if (At <= 0) return;
    if (Archive.Matches.any((Item) => Item.Kind == 'highlight' && (Item.EndAt - At).abs() < 8000)) return;
    final MatchId = 'highlight-$At';
    if (Archive.Matches.any((Item) => Item.MatchId == MatchId)) return;
    final Match = BattleMatch(
      Raw: <String, dynamic>{'createdBy': 'vision'},
      MatchId: MatchId,
      Kind: 'highlight',
      Mode: 'HIGHLIGHT',
      Rule: 'HIGHLIGHT',
      StartAt: At - Config.HighlightLeadMs,
      EndAt: At,
      Duration: Config.HighlightLeadMs,
      Result: 'HIGHLIGHT',
      IsDisconnected: false,
      IsSalmon: false,
      VideoPath: null,
      AccountId: CurrentNSOId,
      AccountNickname: NSOName(),
      SkipReason: null,
      BlurCopy: false,
      TimeExact: true,
      Key: '${CurrentNSOId ?? ''}:$MatchId',
    );
    Archive.Matches.insert(0, Match);
    await Archive.Save(Match);
    Archiving.add(Match.Key);
    PendingHighlights.add(Match.Key);
    HighlightDeadlines[Match.Key] = DateTime.now().millisecondsSinceEpoch + Config.HighlightWaitMs;
    PushStatus();
    unawaited(TryHighlight(Match));
  }

  Future<void> TryHighlight(BattleMatch Match) async {
    final Key = Match.Key;
    final Deadline = HighlightDeadlines[Key];
    if (Deadline == null || Match.HasVideo || Match.SkipReason != null) return;
    if (DateTime.now().millisecondsSinceEpoch > Deadline) {
      await FailHighlight(Match, '高亮画面已过期');
      return;
    }
    final Cache = await Capture.Records();
    if (Cache.isEmpty) {
      RetryHighlight(Match);
      return;
    }
    final Start = Match.StartAt;
    final End = Match.EndAt;
    final Index = Cache.indexWhere((Item) => Item.StartAt <= Start && Item.EndAt >= End);
    if (Index < 0) {
      if (Start < Cache.first.StartAt) {
        await FailHighlight(Match, '高亮画面已过期');
      } else {
        RetryHighlight(Match);
      }
      return;
    }
    final Finalized = Index < Cache.length - 1 || !Capture.Running;
    if (!Finalized && !PlatformInfo.Windows && !PlatformInfo.Linux) {
      RetryHighlight(Match);
      return;
    }
    HighlightTimers.remove(Key)?.cancel();
    ArchiveTask = ArchiveTask.then((_) => ArchiveHighlight(Match));
  }

  Future<void> ArchiveHighlight(BattleMatch Match) async {
    if (Match.HasVideo || Match.SkipReason != null) return;
    final Ok = await ArchiveMatch(Match);
    if (Ok) {
      PendingHighlights.remove(Match.Key);
      HighlightDeadlines.remove(Match.Key);
      HighlightTimers.remove(Match.Key)?.cancel();
      Archiving.remove(Match.Key);
      await Logs.App('highlight archived ${Match.Key} path=${Match.VideoPath}');
      PushStatus();
      return;
    }
    RetryHighlight(Match);
  }

  void RetryHighlight(BattleMatch Match) {
    final Deadline = HighlightDeadlines[Match.Key];
    if (Deadline == null) return;
    if (DateTime.now().millisecondsSinceEpoch > Deadline) {
      unawaited(FailHighlight(Match, '高亮画面裁剪失败'));
      return;
    }
    HighlightTimers.remove(Match.Key)?.cancel();
    HighlightTimers[Match.Key] = Timer(const Duration(milliseconds: Config.HighlightRetryMs), () => unawaited(TryHighlight(Match)));
  }

  Future<void> FailHighlight(BattleMatch Match, String Reason) async {
    Match.SkipReason = Reason;
    await Archive.Save(Match);
    PendingHighlights.remove(Match.Key);
    HighlightDeadlines.remove(Match.Key);
    HighlightTimers.remove(Match.Key)?.cancel();
    Archiving.remove(Match.Key);
    await Logs.App('highlight failed ${Match.Key} $Reason');
    PushStatus();
  }

  WorkResolution ResolveWork(int NsoTime) => Timeline.Resolve(NsoTime);
}
