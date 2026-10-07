import { appendFile } from 'node:fs/promises';
import { join } from 'node:path';
import { logPath } from './path.js';

export function logApp(line: string): void {
  void appendFile(join(logPath, 'app.log'), `${new Date().toISOString()} ${line}\n`, 'utf8').catch(() => undefined);
}
