import type { UpdateAsset } from '../../shared/types.js';

export interface ReleaseAsset {
  name?: string;
  browser_download_url?: string;
  size?: number;
}

export interface ReleaseData {
  tag_name?: string;
  body?: string;
  assets?: ReleaseAsset[];
}

export function releaseUrl(repoUrl: string): string | undefined {
  const match = repoUrl.match(/github\.com[/:]([^/]+)\/([^/#?]+)/i);
  const owner = match?.[1];
  const name = match?.[2]?.replace(/\.git$/i, '');
  return owner && name ? `https://api.github.com/repos/${owner}/${name}/releases/latest` : undefined;
}

export function updateUrls(target: string, prefix: string, proxy: boolean): string[] {
  const proxied = `${prefix}${target}`;
  return proxy ? [proxied, target] : [target, proxied];
}

export function pickAsset(assets: ReleaseAsset[], platform: string, arch: string): UpdateAsset | undefined {
  const usable = assets.filter((item) => typeof item.name === 'string' && typeof item.browser_download_url === 'string');
  const hits = usable.filter((item) => assetPattern(platform).test(String(item.name)));
  if (!hits.length) return undefined;
  const wanted = arch === 'arm64' ? /(arm64|aarch64)/i : /(x64|x86_64|amd64)/i;
  const other = arch === 'arm64' ? /(x64|x86_64|amd64|ia32)/i : /(arm64|aarch64|ia32)/i;
  const best = hits.find((item) => wanted.test(String(item.name)) && !other.test(String(item.name)))
    ?? hits.find((item) => !other.test(String(item.name)))
    ?? hits[0];
  if (!best) return undefined;
  return { name: String(best.name), url: String(best.browser_download_url), size: Number(best.size ?? 0) };
}

export function notesOf(body: string | undefined, limit: number): string | undefined {
  const text = (body ?? '').trim();
  return text ? text.slice(0, limit) : undefined;
}

export function safeFileName(name: string): string {
  return name.replace(/[\\/:*?"<>|]/g, '_').slice(0, 160) || 'update';
}

function assetPattern(platform: string): RegExp {
  if (platform === 'darwin') return /\.dmg$/i;
  if (platform === 'linux') return /\.appimage$/i;
  if (platform === 'win32') return /setup.*\.exe$|\.exe$/i;
  return /\.(exe|dmg|appimage)$/i;
}
