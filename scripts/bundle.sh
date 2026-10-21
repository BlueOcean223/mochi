#!/bin/bash
# 编译并拼成 .app：scripts/bundle.sh [debug|release]，产物是 build/Mochi.app。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Mochi"

APP=build/Mochi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mochi"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# SIGN_IDENTITY 没设就用 ad-hoc 签名。ad-hoc 每次重编签名都会变，辅助功能权限要重新给，
# 所以做到粘贴以后改用固定的自签证书（见 .agent/docs/decisions.md「待定」）。
codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$APP"
echo "$APP"
