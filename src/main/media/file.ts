import { mkdir, stat, unlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export async function ensureDir(folder: string): Promise<void> {
  await mkdir(folder, { recursive: true });
}

export async function removeFile(path: string): Promise<void> {
  await unlink(path).catch(() => undefined);
}

export async function fileExists(path: string): Promise<boolean> {
  try { await stat(path); return true; } catch { return false; }
}

export function safeName(text: string): string {
  const value = text.replace(/[^a-zA-Z0-9]+([a-zA-Z0-9])?/g, (_match, next: string | undefined) => next ? next.toUpperCase() : '');
  const base = !value
    ? 'file'
    : /^[0-9]/.test(value) ? `file${value}` : value[0].toLowerCase() + value.slice(1);
  if (base === text) return base;
  return `${base}h${nameHash(text)}`;
}

function nameHash(text: string): string {
  let hash = 2166136261;
  for (const byte of new TextEncoder().encode(text)) hash = Math.imul(hash ^ byte, 16777619);
  return (hash >>> 0).toString(16).padStart(8, '0');
}

export function legacyName(text: string): string {
  return text.replace(/[^a-zA-Z0-9_-]/g, '_');
}

export async function writeTemp(folder: string, name: string, content: string): Promise<string> {
  const path = join(folder, name);
  await writeFile(path, content, 'utf8');
  return path;
}
