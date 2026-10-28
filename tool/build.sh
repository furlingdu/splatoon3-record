#!/usr/bin/env bash
set -euo pipefail
flutter pub get
flutter test --concurrency=1
if [ "$(uname)" = "Darwin" ]; then
  flutter build macos --release
else
  flutter build linux --release
fi
