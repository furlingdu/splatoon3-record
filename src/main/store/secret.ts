import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { safeStorage } from 'electron';
import { dataPath } from './path.js';
import type { SecretData } from '../../shared/types.js';

const secretFile = join(dataPath, 'secrets.json');

export async function loadSecret(): Promise<SecretData> {
  try {
    const payload = JSON.parse(await readFile(secretFile, 'utf8')) as { encrypted: boolean; value: string };
    const text = payload.encrypted && safeStorage.isEncryptionAvailable()
      ? safeStorage.decryptString(Buffer.from(payload.value, 'base64'))
      : Buffer.from(payload.value, 'base64').toString('utf8');
    return JSON.parse(text) as SecretData;
  } catch {
    return {};
  }
}

export async function saveSecret(data: SecretData): Promise<void> {
  const text = JSON.stringify(data);
  const encrypted = safeStorage.isEncryptionAvailable();
  const buffer = encrypted ? safeStorage.encryptString(text) : Buffer.from(text, 'utf8');
  await writeFile(secretFile, JSON.stringify({ encrypted, value: buffer.toString('base64') }), { mode: 0o600 });
}

export async function clearSecret(keys: (keyof SecretData)[]): Promise<void> {
  const data = await loadSecret();
  for (const key of keys) delete data[key];
  await saveSecret(data);
}
