export interface UpdateInfo {
  version: string;
  url: string;
}

export interface UpdateProvider {
  latest: () => Promise<UpdateInfo | undefined>;
}

export const disabledProvider: UpdateProvider = { latest: async () => undefined };

export function isNewer(current: string, candidate: string): boolean {
  const parse = (version: string) => version.split('.').map((part) => Number(part) || 0);
  const [a, b] = [parse(current), parse(candidate)];
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const diff = (b[index] ?? 0) - (a[index] ?? 0);
    if (diff !== 0) return diff > 0;
  }
  return false;
}

export async function checkUpdate(currentVersion: string, provider: UpdateProvider = disabledProvider): Promise<UpdateInfo | undefined> {
  const info = await provider.latest().catch(() => undefined);
  return info && isNewer(currentVersion, info.version) ? info : undefined;
}
