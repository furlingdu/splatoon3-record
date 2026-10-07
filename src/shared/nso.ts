import type { BattleKind } from './types.js';


export const kindNames: Record<BattleKind, string> = {
  regular: '占地对战',
  anarchyOpen: '蛮颓比赛（开放）',
  anarchySeries: '蛮颓比赛（挑战）',
  xBattle: 'X对战',
  event: '活动挑战',
  splatfest: '蛮颓祭',
  private: '私房对战',
  salmon: '鲑鱼跑',
  unknown: '未知类型',
};


const ruleNames: Record<string, string> = {
  TURF_WAR: '占地对战',
  AREA: '真格区域',
  LOFT: '真格塔楼',
  GOAL: '真格鱼虎对战',
  CLAM: '真格蛤蜊',
  TRI_COLOR: '三色占地对战',
  REGULAR: '平时打工',
  BIG_RUN: '大量发生',
  TEAM_CONTEST: '团队竞赛',
  COOP_NORMAL: '平时打工',
};

export function ruleName(rule: string): string {
  if (!rule || rule.startsWith('[object')) return '未知规则';
  return ruleNames[rule.toUpperCase()] || rule;
}

export function resultText(result: string): string {
  if (/WIN/i.test(result)) return '胜利';
  if (/LOSE/i.test(result)) return '失败';
  if (/DRAW/i.test(result)) return '平局';
  if (/EXEMPTED/i.test(result)) return '无效';
  return '未知结果';
}

export function durationText(duration: number): string {
  const total = Math.max(0, Math.round(duration / 1000));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${minutes}:${String(seconds).padStart(2, '0')}`;
}

export function matchTitle(match: { kind: BattleKind; endAt: number }): string {
  return `${kindNames[match.kind] ?? kindNames.unknown}-${new Date(match.endAt).toLocaleString('zh-CN')}`;
}

export function matchFileName(match: { kind: BattleKind; endAt: number }): string {
  const date = new Date(match.endAt);
  const pad = (value: number): string => String(value).padStart(2, '0');
  const stamp = `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
  return `${kindNames[match.kind] ?? kindNames.unknown}-${stamp}`;
}

export function paintText(value: number | string): string {
  const text = String(value);
  return text && Number.isFinite(Number(value)) ? `${text}p` : text;
}

export function timeText(value: number): string {
  const date = new Date(value);
  const pad = (item: number): string => String(item).padStart(2, '0');
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}
