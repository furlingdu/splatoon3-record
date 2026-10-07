import { execFileSync } from 'node:child_process';

export default function cleanXattr(context) {
  if (process.platform !== 'darwin') return;
  execFileSync('xattr', ['-cr', context.appOutDir], { stdio: 'inherit' });
}
