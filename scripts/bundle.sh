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
# 图标由 scripts/icon.swift 画，改图案时重跑它。
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 辅助功能权限认签名。用登录钥匙串里的自签证书「Mochi Development」签，重编以后签名不变，权限不用重新给。
# 没有这张证书时用 ad-hoc 签名，每次重编都要重新给权限。
# SIGN_IDENTITY 可以指定别的身份，`-` 是 ad-hoc。
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  if security find-certificate -c "Mochi Development" >/dev/null 2>&1; then
    IDENTITY="Mochi Development"
  else
    IDENTITY="-"
  fi
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "$APP"
