import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { dataPath } from './path.js';
import { defaultSettings } from '../../shared/constants.js';
import type { AppConfig, RecordSettings } from '../../shared/types.js';

const configFile = join(dataPath, 'config.json');
const fallback: AppConfig = { settings: { ...defaultSettings, saveDir: join(dataPath, 'videos') }, pushEnabled: true, setupDone: false, handledIds: [] };

let current = fallback;

export async function loadConfig(): Promise<AppConfig> {
  try {
    const data = JSON.parse(await readFile(configFile, 'utf8')) as Partial<AppConfig>;
    current = { ...fallback, ...data, settings: { ...fallback.settings, ...data.settings }, handledIds: data.handledIds ?? [], setupDone: data.setupDone ?? false };
  } catch {
    await saveConfig(fallback);
  }
  return current;
}

export function getConfig(): AppConfig {
  return current;
}

export async function saveConfig(config: AppConfig): Promise<void> {
  current = config;
  await writeFile(configFile, JSON.stringify(config, null, 2), 'utf8');
}

export async function saveSettings(settings: RecordSettings): Promise<AppConfig> {
  const config = { ...current, settings, pushEnabled: settings.autoPush };
  await saveConfig(config);
  return config;
}

export async function markBattle(matchId: string): Promise<void> {
  if (!current.handledIds.includes(matchId)) await saveConfig({ ...current, handledIds: [...current.handledIds.slice(-199), matchId] });
}
