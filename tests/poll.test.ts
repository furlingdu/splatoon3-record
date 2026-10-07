import { afterEach, describe, expect, it, vi } from 'vitest';
import { BattlePoller } from '../src/main/nso/poll.js';
import type { BattleMatch } from '../src/shared/types.js';

const match: BattleMatch = { matchId: 'm1', kind: 'regular', mode: 'REGULAR', rule: 'TURF_WAR', startAt: 1, endAt: 2, duration: 1000, result: 'WIN', isDisconnected: false, isSalmon: false, rawData: {} };

afterEach(() => {
  vi.useRealTimers();
});

describe('BattlePoller', () => {
  it('未处理且晚于基线的对局会进入处理流程', async () => {
    const received = vi.fn().mockResolvedValue(undefined);
    const listed = vi.fn();
    const poller = new BattlePoller({ getBattles: vi.fn().mockResolvedValue([match]) } as never, 1000, () => false, received, vi.fn(), listed);
    poller.start();
    await vi.waitFor(() => expect(received).toHaveBeenCalledWith(match));
    poller.stop();
    expect(listed).toHaveBeenCalledWith([match]);
  });

  it('已处理的对局不会重复进入处理流程', async () => {
    const received = vi.fn().mockResolvedValue(undefined);
    const listed = vi.fn();
    const poller = new BattlePoller({ getBattles: vi.fn().mockResolvedValue([match]) } as never, 1000, () => true, received, vi.fn(), listed);
    poller.start();
    await vi.waitFor(() => expect(listed).toHaveBeenCalledWith([match]));
    poller.stop();
    expect(received).not.toHaveBeenCalled();
  });

  it('查询失败后按退避间隔继续轮询', async () => {
    vi.useFakeTimers();
    const failed = vi.fn();
    const query = { getBattles: vi.fn().mockRejectedValueOnce(new Error('network down')).mockResolvedValue([]) };
    const poller = new BattlePoller(query, 1000, () => false, vi.fn(), failed);
    poller.start();
    await Promise.resolve();
    expect(failed).toHaveBeenCalledWith(expect.any(Error));
    expect(query.getBattles).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1999);
    expect(query.getBattles).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    await Promise.resolve();
    expect(query.getBattles).toHaveBeenCalledTimes(2);
    poller.stop();
  });
});
