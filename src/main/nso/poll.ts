import type { BattleMatch } from '../../shared/types.js';
import type { BattleQuery } from './query.js';

export class BattlePoller {
  private timer?: NodeJS.Timeout;
  private failures = 0;
  private running = false;
  constructor(private query: BattleQuery, private interval: number, private handled: (match: BattleMatch) => boolean, private received: (match: BattleMatch) => Promise<void>, private failed: (error: Error) => void, private listed: (matches: BattleMatch[]) => void = () => {}) {}

  start(): void { if (!this.running) { this.running = true; void this.poll(); } }
  stop(): void { this.running = false; if (this.timer) clearTimeout(this.timer); }

  async poll(): Promise<void> {
    if (!this.running) return;
    try {
      const matches = await this.query.getBattles();
      this.failures = 0;
      this.listed(matches);
      for (const match of [...matches].reverse()) if (!this.handled(match)) void this.received(match).catch((error) => this.failed(error instanceof Error ? error : new Error(String(error))));
    } catch (error) {
      this.failures += 1;
      this.failed(error instanceof Error ? error : new Error(String(error)));
    } finally {
      if (this.running) this.timer = setTimeout(() => void this.poll(), Math.min(this.interval * 2 ** this.failures, 15 * 60000));
    }
  }
}
