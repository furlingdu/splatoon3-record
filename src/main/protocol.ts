import { protocol } from 'electron';
import { createReadStream, existsSync } from 'node:fs';
import { stat } from 'node:fs/promises';
import { Readable } from 'node:stream';
import { parseRange } from './media/range.js';
import { parseVideoUrl } from './media/video.js';
import type { BattleMatch } from '../shared/types.js';

export function registerVideoProtocol(matches: () => BattleMatch[]): void {
  protocol.handle('s3r-video', async (request) => {
    const matchId = parseVideoUrl(request.url);
    if (!matchId) return new Response('录像地址无效', { status: 400 });
    const match = matches().find((item) => item.matchId === matchId);
    const file = match?.videoPath;
    if (!file || !existsSync(file)) return new Response('未找到录像', { status: 404 });
    const info = await stat(file).catch(() => undefined);
    if (!info) return new Response('未找到录像', { status: 404 });
    const range = parseRange(request.headers.get('range'), info.size);
    if (range) {
      const stream = Readable.toWeb(createReadStream(file, { start: range.start, end: range.end })) as ReadableStream;
      return new Response(stream, {
        status: 206,
        headers: {
          'Accept-Ranges': 'bytes',
          'Content-Type': 'video/mp4',
          'Content-Length': String(range.end - range.start + 1),
          'Content-Range': `bytes ${range.start}-${range.end}/${info.size}`,
          'Access-Control-Allow-Origin': '*',
        },
      });
    }
    const stream = Readable.toWeb(createReadStream(file)) as ReadableStream;
    return new Response(stream, {
      status: 200,
      headers: {
        'Accept-Ranges': 'bytes',
        'Content-Type': 'video/mp4',
        'Content-Length': String(info.size),
        'Access-Control-Allow-Origin': '*',
      },
    });
  });
}
