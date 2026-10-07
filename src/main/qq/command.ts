import type { BattleMatch, UserMessage } from '../../shared/types.js';
import { kindNames, paintText, resultText, ruleName, timeText } from '../../shared/nso.js';

export type QqCommand = 'bind' | 'record' | 'last' | 'push' | 'status' | 'unknown';

export function parseCommand(content: string): QqCommand {
  const command = content.trim().split(/\s+/)[0].toLowerCase().replace(/^\//, '');
  if (['bind', 'record', 'last', 'push', 'status'].includes(command)) return command as QqCommand;
  return 'unknown';
}

export function matchText(match?: BattleMatch): string {
  if (!match) return '尚无对局记录';
  return matchDetails(match).join('\n');
}

export function pushText(match?: BattleMatch): string {
  if (!match) return '新对局，未成功录制对局';
  const status = match.videoPath ? '已成功录制对局' : '未成功录制对局';
  const lines = [`# 新对局，${status}`, '', ...matchDetails(match)];
  if (match.videoPath) lines.push('', '本条消息附带的视频已压制为 1080p60');
  return lines.join('\n');
}

function matchDetails(match: BattleMatch): string[] {
  const lines = [
    '| 项目 | 内容 |',
    '| --- | --- |',
    `| 模式 | ${cellText(kindNames[match.kind] || kindNames.unknown)} |`,
    `| 规则 | ${cellText(ruleName(match.rule))} |`,
    `| 结果 | ${cellText(resultText(match.result))} |`,
    `| 时间 | ${timeText(match.startAt)} ~ ${timeText(match.endAt)} |`,
    `| 耗时 | ${durationLine(match.duration)} |`,
    `| 是否掉线 | ${match.isDisconnected ? '是' : '否'} |`,
  ];
  const roster = playerLines(match);
  if (roster.length) lines.push('', '**角色战绩**', '', ...roster);
  return lines;
}

function playerLines(match: BattleMatch): string[] {
  const detail = matchDetail(match);
  if (!detail) return [];
  const rows: string[] = [];
  const my = teamPlayers(detail.myTeam);
  const enemies = asArray(detail.otherTeams).flatMap((team) => teamPlayers(team));
  if (my.length || enemies.length) {
    rows.push('| 队伍 | 玩家 | 武器 | 击杀（助攻） | 击倒 | 大招 | K/D | 涂地 |', '| --- | --- | --- | --- | --- | --- | --- | --- |');
    rows.push(...my.map((player) => playerRow('我方', player)));
    rows.push(...enemies.map((player) => playerRow('敌方', player)));
  }
  const members = coopRows(detail);
  if (members.length) rows.push('', '**成员**', '', '| 玩家 | 武器 | 击杀 | 运送 | 救援 |', '| --- | --- | --- | --- | --- |', ...members);
  return rows;
}

function matchDetail(match: BattleMatch): Record<string, unknown> | undefined {
  const raw = recordValue(match.rawData);
  const data = recordValue(raw?.data ?? raw);
  return recordValue(data?.vsHistoryDetail ?? data?.coopHistoryDetail ?? data);
}

function teamPlayers(value: unknown): Record<string, unknown>[] {
  const team = recordValue(value);
  return asArray(team?.players).map((item) => recordValue(item)).filter((item): item is Record<string, unknown> => Boolean(item));
}

function playerRow(team: string, player: Record<string, unknown>): string {
  const name = textValue(player.name) || textValue(player.byname) || '未知';
  const displayName = player.isMyself ? `[你] ${name}` : name;
  const weapon = weaponText(player.weapon);
  const result = recordValue(player.result);
  const killOrAssist = integerText(result?.kill);
  const assist = integerText(result?.assist);
  const kill = killOrAssist === '?' || assist === '?' ? '?' : String(Math.max(0, Number(killOrAssist) - Number(assist)));
  const death = integerText(result?.death);
  const special = integerText(result?.special);
  const paint = integerText(player.paint);
  return `| ${cellText(team)} | ${cellText(displayName)} | ${cellText(weapon)} | ${kill}（${assist}） | ${killOrAssist} | ${special} | ${kill}/${death}（${kdText(kill, death)}） | ${paintText(paint)} |`;
}

function coopRows(detail: Record<string, unknown>): string[] {
  const values = [detail.myResult, ...asArray(detail.memberResults)];
  return values.flatMap((item) => {
    const member = recordValue(item);
    if (!member) return [];
    const player = recordValue(member.player);
    const name = textValue(player?.name) || textValue(player?.byname) || '未知';
    const weapon = weaponText(asArray(member.weapons)[0]);
    const displayName = player?.isMyself ? `[你] ${name}` : name;
    return [`| ${cellText(displayName)} | ${cellText(weapon)} | ${integerText(member.defeatEnemyCount)} | ${integerText(member.deliverCount)} | ${integerText(member.rescueCount)} |`];
  });
}

function weaponText(value: unknown): string {
  const item = recordValue(value);
  return textValue(item?.name) || textValue(item?.weaponName) || textValue(value) || '未知武器';
}

function cellText(value: string): string {
  return value.replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');
}

function recordValue(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === 'object' ? value as Record<string, unknown> : undefined;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function textValue(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function integerText(value: unknown): string {
  const number = Number(value);
  return Number.isFinite(number) ? String(number) : '?';
}

function kdText(kill: unknown, death: unknown): string {
  const killed = Number(kill);
  const died = Number(death);
  if (!Number.isFinite(killed) || killed < 0) return '?';
  if (!Number.isFinite(died) || died <= 0) return '-';
  return (killed / died).toFixed(2);
}

function durationLine(duration: number): string {
  const total = Math.max(0, Math.round(duration / 1000));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  if (minutes === 0) return `${seconds}s`;
  return seconds === 0 ? `${minutes}min` : `${minutes}min${seconds}s`;
}

export function makeMessage(content: string, senderId: string, target: unknown, isPrivate: boolean): UserMessage {
  return { content, senderId, target, isPrivate, isProxy: true };
}
