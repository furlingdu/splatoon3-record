import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, createWriteStream, existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs';
import { get } from 'node:https';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pipeline } from 'node:stream/promises';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const runExe = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';
const target = join(root, 'bin', runExe);
const tempDir = join(root, 'bin', 'tmp');
const force = process.argv.includes('--force');

const packages = {
  win32: { url: 'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip', archive: 'ffmpeg.zip' },
  linux: { url: 'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-linux64-gpl.tar.xz', archive: 'ffmpeg.tar.xz' },
};
const darwinUrl = 'https://github.com/eugeneware/ffmpeg-static/releases/latest/download/ffmpeg-darwin-arm64';

function ffmpegVersion(file) {
  const result = spawnSync(file, ['-hide_banner', '-version'], { encoding: 'utf8' });
  if (result.status !== 0) return '';
  return (result.stdout || '').split(/\r?\n/)[0] ?? '';
}

function download(url, file) {
  return new Promise((resolve, reject) => {
    const request = get(url, { headers: { 'user-agent': 'splatoon3record-build' } }, (response) => {
      if (response.statusCode && response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
        response.resume();
        download(response.headers.location, file).then(resolve, reject);
        return;
      }
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`下载失败 ${response.statusCode} ${url}`));
        return;
      }
      pipeline(response, createWriteStream(file)).then(resolve, reject);
    });
    request.on('error', reject);
  });
}

function runTool(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  return result.status === 0;
}

function findTool(names, versions) {
  for (const name of names) {
    const result = spawnSync(name, versions, { encoding: 'utf8' });
    if (!result.error) return name;
  }
  return '';
}

function findExtractedBinary(folder) {
  const direct = join(folder, runExe);
  if (existsSync(direct)) return direct;
  const entries = readdirSync(folder, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const nested = findExtractedBinary(join(folder, entry.name));
    if (nested) return nested;
  }
  return '';
}

function extractZip(archive, folder) {
  const sevenZip = findTool(['7z', 'C:/Program Files/7-Zip/7z.exe'], ['i']);
  if (sevenZip && runTool(sevenZip, ['x', archive, `-o${folder}`, '-y'])) {
    const picked = findExtractedBinary(folder);
    if (picked) copyFileSync(picked, join(folder, runExe));
    return Boolean(picked);
  }
  const tar = findTool(['tar'], ['--version']);
  if (tar && runTool(tar, ['-xf', archive, '-C', folder])) {
    const picked = findExtractedBinary(folder);
    if (picked) copyFileSync(picked, join(folder, runExe));
    return Boolean(picked);
  }
  const powershell = findTool(['powershell'], ['-Command', 'exit 0']);
  if (!powershell) return false;
  const script = `Expand-Archive -LiteralPath '${archive}' -DestinationPath '${folder}' -Force`;
  if (!runTool(powershell, ['-NoProfile', '-NonInteractive', '-Command', script])) return false;
  const picked = findExtractedBinary(folder);
  if (picked) copyFileSync(picked, join(folder, runExe));
  return Boolean(picked);
}

function extractTar(archive, folder) {
  const tar = findTool(['tar'], ['--version']);
  if (!tar || !runTool(tar, ['-xJf', archive, '-C', folder])) return false;
  const picked = findExtractedBinary(folder);
  if (picked) copyFileSync(picked, join(folder, runExe));
  return Boolean(picked);
}

async function fetchBinary() {
  const pack = packages[process.platform] ?? packages.linux;
  mkdirSync(tempDir, { recursive: true });
  const archive = join(tempDir, pack.archive);
  console.log(`下载 ${pack.url}`);
  await download(pack.url, archive);
  const ok = pack.archive.endsWith('.zip') ? extractZip(archive, tempDir) : extractTar(archive, tempDir);
  rmSync(archive, { force: true });
  const picked = join(tempDir, runExe);
  if (!ok || !existsSync(picked)) throw new Error('解压 ffmpeg 失败，请手工将 ffmpeg 放入 bin 目录');
  mkdirSync(dirname(target), { recursive: true });
  copyFileSync(picked, target);
  rmSync(picked, { force: true });
}

async function fetchDarwin() {
  mkdirSync(tempDir, { recursive: true });
  const picked = join(tempDir, runExe);
  console.log(`下载 ${darwinUrl}`);
  await download(darwinUrl, picked);
  chmodSync(picked, 0o755);
  mkdirSync(dirname(target), { recursive: true });
  copyFileSync(picked, target);
  chmodSync(target, 0o755);
  rmSync(picked, { force: true });
}

async function main() {
  if (!force && existsSync(target) && ffmpegVersion(target).includes('ffmpeg version')) {
    console.log(`复用已有 ${runExe}：${ffmpegVersion(target)}`);
    return;
  }
  if (process.platform === 'darwin') await fetchDarwin(); else await fetchBinary();
  const version = ffmpegVersion(target);
  if (!version.includes('ffmpeg version')) throw new Error('ffmpeg 校验失败');
  console.log(`${version} 已就绪 ${statSync(target).size} 字节`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
