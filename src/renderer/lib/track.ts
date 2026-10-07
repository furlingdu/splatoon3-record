import type { DetectBox } from './detect.js';

export interface TrackBox extends DetectBox {
  vx: number;
  vy: number;
  at: number;
  seen: number;
}

const leadLimit = 350;
const keepMs = 200;
const speedLimit = 20;
const blend = 0.25;

export function updateTracks(tracks: TrackBox[], boxes: DetectBox[], at: number, seen: number): TrackBox[] {
  const next: TrackBox[] = [];
  const used = new Set<TrackBox>();
  for (const box of boxes) {
    const track = matchTrack(tracks, used, box, at);
    if (!track) {
      next.push({ ...box, vx: 0, vy: 0, at, seen });
      continue;
    }
    used.add(track);
    const gap = Math.max(16, at - track.at);
    const speed = limitSpeed((centerX(box) - centerX(track)) / gap, (centerY(box) - centerY(track)) / gap);
    const steady = track.vx === 0 && track.vy === 0;
    next.push({
      ...box,
      vx: steady ? speed.vx : blend * track.vx + (1 - blend) * speed.vx,
      vy: steady ? speed.vy : blend * track.vy + (1 - blend) * speed.vy,
      at,
      seen,
    });
  }
  for (const track of tracks) {
    if (used.has(track) || seen - track.seen > keepMs) continue;
    next.push({ ...track, vx: track.vx / 2, vy: track.vy / 2 });
  }
  return next;
}

export function predictBoxes(tracks: TrackBox[], now: number): DetectBox[] {
  return tracks.map((track) => {
    const lead = Math.min(leadLimit, Math.max(0, now - track.at));
    return {
      x: track.x + track.vx * lead,
      y: track.y + track.vy * lead,
      width: track.width,
      height: track.height,
    };
  });
}

function matchTrack(tracks: TrackBox[], used: Set<TrackBox>, box: DetectBox, at: number): TrackBox | undefined {
  const x = centerX(box);
  const y = centerY(box);
  const reach = Math.max(80, Math.max(box.width, box.height) * 0.9);
  let best: TrackBox | undefined;
  let bestGap = 0;
  for (const track of tracks) {
    if (used.has(track)) continue;
    const lead = Math.min(leadLimit, Math.max(0, at - track.at));
    const gap = Math.hypot(x - (centerX(track) + track.vx * lead), y - (centerY(track) + track.vy * lead));
    if (gap > reach) continue;
    if (best && gap >= bestGap) continue;
    best = track;
    bestGap = gap;
  }
  return best;
}

function limitSpeed(vx: number, vy: number): { vx: number; vy: number } {
  const speed = Math.hypot(vx, vy);
  if (speed <= speedLimit) return { vx, vy };
  const ratio = speedLimit / speed;
  return { vx: vx * ratio, vy: vy * ratio };
}

function centerX(box: DetectBox): number {
  return box.x + box.width / 2;
}

function centerY(box: DetectBox): number {
  return box.y + box.height / 2;
}
