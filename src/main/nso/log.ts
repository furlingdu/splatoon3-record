import { appendFile } from 'node:fs/promises';
import { join } from 'node:path';
import { logPath } from '../store/path.js';

export function logLogin(line: string): void {
  void appendFile(join(logPath, 'loginDebug.log'), `${new Date().toISOString()} ${line}\n`, 'utf8').catch(() => undefined);
}
