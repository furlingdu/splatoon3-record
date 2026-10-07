import { describe, expect, it } from 'vitest';
import { makeMessage, matchText, parseCommand, pushText } from '../src/main/qq/command.js';
import { paintText } from '../src/shared/nso.js';

describe('paintText', () => {
  it('为涂地数值添加 p 后缀并保留未知值', () => {
    expect(paintText(8718)).toBe('8718p');
    expect(paintText('?')).toBe('?');
  });
});

describe('parseCommand', () => {
  it('解析支持的命令', () => {
    expect(parseCommand('/bind')).toBe('bind');
    expect(parseCommand('/RECORD')).toBe('record');
    expect(parseCommand('  /last  ')).toBe('last');
    expect(parseCommand('/push')).toBe('push');
    expect(parseCommand('/status')).toBe('status');
  });

  it('未知命令返回 unknown', () => {
    expect(parseCommand('/help')).toBe('unknown');
    expect(parseCommand('你好')).toBe('unknown');
    expect(parseCommand('')).toBe('unknown');
  });
});

describe('matchText', () => {
  it('无对局时返回提示', () => {
    expect(matchText()).toBe('尚无对局记录');
  });

  it('输出对局信息文本', () => {
    const text = matchText({ kind: 'regular', rule: 'TURF_WAR', result: 'WIN', startAt: 1700000000000 - 180000, endAt: 1700000000000, duration: 180000, isDisconnected: false } as never);
    expect(text).toContain('| 模式 | 占地对战 |');
    expect(text).toContain('| 结果 | 胜利 |');
    expect(text).toContain('| 耗时 | 3min |');
    expect(text).toContain('| 是否掉线 | 否 |');
    expect(text).toMatch(/\| 时间 \| \d{2}:\d{2}:\d{2} ~ \d{2}:\d{2}:\d{2} \|/);
    expect(text).not.toMatch(/\d{4}\/\d{1,2}\/\d{1,2}/);
  });

  it('推送文本包含录制状态与角色详情', () => {
    const text = pushText({
      kind: 'anarchySeries', rule: 'CLAM', result: 'WIN', startAt: 1700000000000 - 180000, endAt: 1700000000000, duration: 180000, isDisconnected: false, videoPath: 'D:/videos/占地对战-20260916-221530.mp4', rawData: {
        data: { vsHistoryDetail: { myTeam: { players: [{ name: 'Love', isMyself: true, weapon: { name: '巨齿刮水刀' }, paint: 1419, result: { kill: 12, death: 5, assist: 2, special: 5 } }] }, otherTeams: [] } },
      },
    } as never);
    expect(text).toContain('新对局，已成功录制对局');
    expect(text).toContain('| 模式 | 蛮颓比赛（挑战） |');
    expect(text).toContain('| 规则 | 真格蛤蜊 |');
    expect(text).toContain('| 玩家 | 武器 |');
    expect(text).toContain('| 我方 | [你] Love | 巨齿刮水刀 |');
    expect(text).toContain('| 10（2） | 12 | 5 |');
    expect(text).toContain('| 1419p |');
    expect(text).toContain('本条消息附带的视频已压制为 1080p60');
    expect(text).not.toContain('当前视频路径');
    expect(text).not.toContain('原视频请前往录制文件夹获取');
  });

  it('未录制成功时不写视频路径', () => {
    const text = pushText({ kind: 'regular', rule: 'TURF_WAR', result: 'LOSE', startAt: 0, endAt: 1000, duration: 1000, isDisconnected: false, rawData: {} } as never);
    expect(text).toContain('未成功录制对局');
    expect(text).not.toContain('当前视频路径');
    expect(text).not.toContain('压制为 1080p60');
  });

  it('输出双方角色战绩', () => {
    const text = matchText({
      kind: 'regular',
      rule: 'TURF_WAR',
      result: 'WIN',
      startAt: 1700000000000 - 180000,
      endAt: 1700000000000,
      duration: 180000,
      isDisconnected: false,
      rawData: {
        data: {
          vsHistoryDetail: {
            myTeam: {
              players: [
                { name: 'Love', isMyself: true, weapon: { name: '斯普拉射击枪' }, result: { kill: 12, death: 5, assist: 2, special: 5 } },
              ],
            },
            otherTeams: [
              {
                players: [
                  { name: 'Opponent', isMyself: false, weapon: { name: '电动马达滚筒' }, result: { kill: 14, death: 7, assist: 4, special: 7 } },
                ],
              },
            ],
          },
        },
      },
    } as never);
    expect(text).toContain('**角色战绩**');
    expect(text).toContain('| 我方 | [你] Love | 斯普拉射击枪 |');
    expect(text).toContain('| 敌方 | Opponent | 电动马达滚筒 |');
    expect(text).toContain('| 10（2） | 12 | 5 |');
    expect(text).toContain('| 10（4） | 14 | 7 |');
  });

  it('武器名称直接使用 NSO 返回值', () => {
    const text = matchText({
      kind: 'regular', rule: 'TURF_WAR', result: 'WIN', startAt: 1, endAt: 2, duration: 1000, isDisconnected: false,
      rawData: { data: { vsHistoryDetail: { myTeam: { players: [{ name: 'Player', weapon: { name: '碳纖維滾筒 裝飾' }, result: {} }] }, otherTeams: [] } } },
    } as never);
    expect(text).toContain('碳纖維滾筒 裝飾');
    expect(text).not.toContain('碳纤维滚筒');
  });
});

describe('makeMessage', () => {
  it('构造私聊消息并标记代理来源', () => {
    const message = makeMessage('/bind', 'openid-1', { id: 1 }, true);
    expect(message.content).toBe('/bind');
    expect(message.senderId).toBe('openid-1');
    expect(message.isPrivate).toBe(true);
    expect(message.isProxy).toBe(true);
  });
});
