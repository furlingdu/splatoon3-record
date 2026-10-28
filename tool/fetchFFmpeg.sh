#!/usr/bin/env bash
set -euo pipefail

Root="$(cd "$(dirname "$0")/.." && pwd)"
Target="${1:-}"

case "$Target" in
  macos-arm64)
    Url="https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64"
    ;;
  macos-x64)
    Url="https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-x64"
    ;;
  linux-x64)
    Url="https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-linux-x64"
    ;;
  linux-arm64)
    Url="https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-linux-arm64"
    ;;
  *)
    echo "unknown target: $Target"
    exit 1
    ;;
esac

mkdir -p "$Root/assets/tools"
curl -fL --retry 5 --retry-all-errors -o "$Root/assets/tools/ffmpeg" "$Url"
chmod +x "$Root/assets/tools/ffmpeg"

if [ "$(uname)" = "Darwin" ]; then
  codesign --force --sign - "$Root/assets/tools/ffmpeg"
fi

"$Root/assets/tools/ffmpeg" -version | head -n 1
