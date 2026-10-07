import { matchClock } from './clock.js';
import type { BattleKind, BattleMatch } from '../../shared/types.js';

const kindNames: Record<string, BattleKind> = {
  REGULAR: 'regular',
  BANKARA_OPEN: 'anarchyOpen',
  BANKARA_CHALLENGE: 'anarchySeries',
  BANKARA: 'anarchyOpen',
  X_MATCH: 'xBattle',
  LEAGUE: 'event',
  FEST: 'splatfest',
  PRIVATE: 'private',
  COOP: 'salmon',
};

export function battleKind(mode: unknown, rule: unknown, salmon = false, bankaraMode = ''): BattleKind {
  if (salmon || String(mode).startsWith('COOP')) return 'salmon';
  const text = `${String(mode)} ${String(rule)}`.toUpperCase();
  if (text.includes('PRIVATE')) return 'private';
  if (text.includes('FEST')) return 'splatfest';
  if (text.includes('X_MATCH') || text.includes('X MATCH')) return 'xBattle';
  if (/CHALLENGE/i.test(bankaraMode)) return 'anarchySeries';
  if (/OPEN/i.test(bankaraMode)) return 'anarchyOpen';
  if (text.includes('BANKARA') && text.includes('CHALLENGE')) return 'anarchySeries';
  if (text.includes('BANKARA')) return 'anarchyOpen';
  if (text.includes('LEAGUE') || text.includes('EVENT')) return 'event';
  if (text.includes('REGULAR') || text.includes('TURF')) return 'regular';
  return kindNames[String(mode).toUpperCase()] ?? 'unknown';
}

function valueOf(data: Record<string, unknown>, keys: string[]): unknown {
  for (const key of keys) if (data[key] !== undefined && data[key] !== null) return data[key];
  return undefined;
}

function textValue(value: unknown): string {
  if (typeof value === 'string' || typeof value === 'number') return String(value);
  if (value && typeof value === 'object') {
    const item = value as Record<string, unknown>;
    return String(item.mode ?? item.rule ?? item.name ?? item.coopRule ?? '');
  }
  return '';
}

export function normalizeBattle(raw: unknown, salmon = false): BattleMatch | undefined {
  if (!raw || typeof raw !== 'object') return undefined;
  const data = raw as Record<string, unknown>;
  const root = (data.data ?? data) as Record<string, unknown>;
  const detail = (root.vsHistoryDetail ?? root.coopHistoryDetail ?? root) as Record<string, unknown>;
  const id = String(valueOf(detail, ['id', 'matchId', 'uuid']) ?? '');
  if (!id) return undefined;
  const durationValue = Number(valueOf(detail, ['duration', 'durationMs']) ?? 0);
  const duration = Number.isFinite(durationValue) ? (durationValue > 10000 ? durationValue : durationValue * 1000) : 0;
  const played = valueOf(detail, ['playedTime', 'playedAt']);
  const ended = valueOf(detail, ['endAt', 'endedAt']);
  const playedAt = typeof played === 'number' ? played : Date.parse(String(played ?? ''));
  const endedAt = typeof ended === 'number' ? ended : Date.parse(String(ended ?? ''));
  const endAt = Number.isFinite(endedAt) ? endedAt : Number.isFinite(playedAt) ? playedAt + duration : Date.now();
  const clock = matchClock(Number.isFinite(endAt) ? endAt : Date.now(), duration);
  const mode = textValue(valueOf(detail, ['vsMode', 'mode', 'coopRule']));
  const rule = textValue(valueOf(detail, ['rule', 'vsRule', 'coopStage']));
  const bankara = valueOf(detail, ['bankaraMatch']) as Record<string, unknown> | undefined;
  const judgement = String(valueOf(detail, ['judgement', 'result', 'outcome']) ?? '');
  const disconnected = Boolean(valueOf(detail, ['isDisconnected', 'disconnected'])) || /DISCONNECT|EXEMPTED/i.test(judgement);
  return { matchId: id, kind: battleKind(mode, rule, salmon, textValue(bankara)), mode, rule, startAt: clock.startAt, endAt: clock.endAt, duration: clock.duration, result: judgement, isDisconnected: disconnected, isSalmon: salmon || /COOP|SALMON/i.test(mode) || Boolean(detail.coopStage), rawData: raw };
}

export function normalizeList(raw: unknown): BattleMatch[] {
  const values: { raw: unknown; salmon: boolean }[] = [];
  if (Array.isArray(raw)) values.push(...raw.map((item) => ({ raw: item, salmon: Boolean(item && typeof item === 'object' && 'coopHistoryDetail' in item) })));
  else if (raw && typeof raw === 'object') {
    const data = raw as Record<string, unknown>;
    const root = (data.data ?? data) as Record<string, unknown>;
    const battle = root.latestBattleHistories ?? root.battleHistories ?? root.regularBattleHistories;
    const coop = root.coopResult ?? root.coopHistory;
    for (const [source, salmon] of [[battle, false], [coop, true]] as [unknown, boolean][]) {
      if (!source || typeof source !== 'object') continue;
      const groups = (source as Record<string, unknown>).historyGroups as Record<string, unknown> | undefined;
      for (const group of (groups?.nodes as unknown[] | undefined) ?? []) {
        const details = (group as Record<string, unknown>).historyDetails as Record<string, unknown> | undefined;
        values.push(...((details?.nodes as unknown[] | undefined) ?? []).map((raw) => ({ raw, salmon })));
      }
      values.push(...(((source as Record<string, unknown>).nodes as unknown[]) ?? []).map((raw) => ({ raw, salmon })));
    }
  }
  return values.map(({ raw, salmon }) => normalizeBattle(raw, salmon || Boolean(raw && typeof raw === 'object' && 'coopHistoryDetail' in raw))).filter((item): item is BattleMatch => Boolean(item));
}
