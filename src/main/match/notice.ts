import { statfs } from 'node:fs/promises';

const diskFloorBytes = 2 * 1024 * 1024 * 1024;

export async function diskShortage(folder: string): Promise<boolean> {
  const info = await statfs(folder).catch(() => undefined);
  if (!info) return false;
  return Number(info.bavail) * Number(info.bsize) < diskFloorBytes;
}

export function failureReason(error: unknown): string {
  const text = `${error instanceof Error ? error.message : String(error ?? '')}`.toLowerCase();
  if (/enospc|no space left|quota|磁盘|disk|space/.test(text)) return '磁盘空间不足';
  if (/timeout|etimedout|超时/.test(text)) return '处理超时';
  if (/device|capture|采集|设备|readable|overconstrained|notfound/.test(text)) return '采集设备中断或被占用';
  if (/encoder|nvenc|amf|qsv|codec|ffmpeg|编码|解码|decode/.test(text)) return '视频编码器不可用或驱动异常';
  return '录制过程中出现未知错误';
}
