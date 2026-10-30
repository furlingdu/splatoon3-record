enum WorkEventKind { start, end, result }

class WorkEvent {
  WorkEvent({required this.Kind, required this.At, required this.Confidence, this.Consumed = false});

  final WorkEventKind Kind;
  final int At;
  final double Confidence;
  bool Consumed;
}

class WorkResolution {
  const WorkResolution({required this.StartAt, required this.EndAt, required this.Exact, required this.Source});

  final int StartAt;
  final int EndAt;
  final bool Exact;
  final String Source;

  int get Duration => EndAt > StartAt ? EndAt - StartAt : 0;
}

class WorkTimeline {
  WorkTimeline({this.RetainMs = 30 * 60 * 1000});

  final int RetainMs;
  final List<WorkEvent> Events = <WorkEvent>[];

  void Add(WorkEventKind Kind, int At, double Confidence) {
    if (At <= 0) return;
    Events.add(WorkEvent(Kind: Kind, At: At, Confidence: Confidence));
    Events.sort((Left, Right) => Left.At.compareTo(Right.At));
  }

  void Trim(int Now) {
    Events.removeWhere((Item) => Now - Item.At > RetainMs);
  }

  WorkResolution Resolve(int NsoTime) {
    final EndEvent = Nearest(WorkEventKind.end, NsoTime, 120000) ?? Nearest(WorkEventKind.result, NsoTime, 120000);
    if (EndEvent != null) {
      final EndAt = EndEvent.At;
      var StartEvent = Latest(WorkEventKind.start, EndAt - 20 * 60 * 1000, EndAt);
      var Exact = StartEvent != null;
      var Source = 'end';
      if (StartEvent == null) {
        final StartNear = Nearest(WorkEventKind.start, NsoTime, 30000);
        final LaterEnd = StartNear == null ? null : Next(WorkEventKind.end, StartNear.At);
        if (StartNear != null && LaterEnd != null) {
          StartEvent = StartNear;
          EndEvent.Consumed = true;
          LaterEnd.Consumed = true;
          StartNear.Consumed = true;
          return WorkResolution(StartAt: StartNear.At, EndAt: LaterEnd.At, Exact: true, Source: 'start-after-nso');
        }
        Exact = false;
        Source = 'end-fallback';
      }
      final StartAt = StartEvent?.At ?? EndAt - 600000;
      StartEvent?.Consumed = true;
      EndEvent.Consumed = true;
      return WorkResolution(
        StartAt: StartAt < EndAt ? StartAt : EndAt - 600000,
        EndAt: EndAt,
        Exact: Exact,
        Source: Source,
      );
    }
    final StartEvent = Nearest(WorkEventKind.start, NsoTime, 30000);
    if (StartEvent != null) {
      final LaterEnd = Next(WorkEventKind.end, StartEvent.At) ?? Next(WorkEventKind.result, StartEvent.At);
      if (LaterEnd != null) {
        StartEvent.Consumed = true;
        LaterEnd.Consumed = true;
        return WorkResolution(StartAt: StartEvent.At, EndAt: LaterEnd.At, Exact: true, Source: 'start-after-nso');
      }
      StartEvent.Consumed = true;
      return WorkResolution(StartAt: StartEvent.At, EndAt: NsoTime > StartEvent.At ? NsoTime : StartEvent.At + 600000, Exact: false, Source: 'start-only');
    }
    return WorkResolution(StartAt: NsoTime - 600000, EndAt: NsoTime, Exact: false, Source: 'fallback');
  }

  WorkEvent? Nearest(WorkEventKind Kind, int At, int Window) {
    WorkEvent? Found;
    var Best = Window + 1;
    for (final Item in Events) {
      if (Item.Kind != Kind || Item.Consumed) continue;
      final Distance = (Item.At - At).abs();
      if (Distance > Window || Distance >= Best) continue;
      Best = Distance;
      Found = Item;
    }
    return Found;
  }

  WorkEvent? Latest(WorkEventKind Kind, int From, int To) {
    WorkEvent? Found;
    for (final Item in Events) {
      if (Item.Kind != Kind || Item.Consumed) continue;
      if (Item.At < From || Item.At > To) continue;
      if (Found == null || Item.At > Found.At) Found = Item;
    }
    return Found;
  }

  WorkEvent? Next(WorkEventKind Kind, int After) {
    WorkEvent? Found;
    for (final Item in Events) {
      if (Item.Kind != Kind || Item.Consumed) continue;
      if (Item.At <= After) continue;
      if (Found == null || Item.At < Found.At) Found = Item;
    }
    return Found;
  }

  WorkEvent? NextAny(int After) {
    WorkEvent? Found;
    for (final Item in Events) {
      if (Item.Consumed) continue;
      if (Item.At <= After) continue;
      if (Found == null || Item.At < Found.At) Found = Item;
    }
    return Found;
  }
}

class DetectionGate {
  DetectionGate({
    required this.RequiredHits,
    required this.CooldownMs,
    this.ReleaseMs = 2000,
  });

  final int RequiredHits;
  final int CooldownMs;
  final int ReleaseMs;
  int Hits = 0;
  int Misses = 0;
  int FirstSeenAt = 0;
  int LastSeenAt = 0;
  int LastFiredAt = 0;
  bool Fired = false;

  int? Update(int Now, bool Seen, int IntervalMs) {
    if (Seen) {
      Hits++;
      Misses = 0;
      LastSeenAt = Now;
      if (FirstSeenAt == 0) FirstSeenAt = Now;
      if (Fired) return null;
      if (Hits < RequiredHits) return null;
      if (LastFiredAt > 0 && Now - LastFiredAt < CooldownMs) return null;
      Fired = true;
      LastFiredAt = Now;
      return FirstSeenAt;
    }
    Misses++;
    Hits = 0;
    if (!Fired) {
      if (Misses * IntervalMs >= ReleaseMs) FirstSeenAt = 0;
      return null;
    }
    if (Misses * IntervalMs >= ReleaseMs) {
      Fired = false;
      FirstSeenAt = 0;
    }
    return null;
  }
}
