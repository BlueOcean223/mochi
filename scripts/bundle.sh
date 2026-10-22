#!/bin/bash
# 编译并拼成 .app：scripts/bundle.sh [debug|release]，产物是 build/Mochi.app。
# MOCHI_APP 可以换产物的位置（测试用的构建放别处，不盖掉平常用的那个）。
# MOCHI_VERSION、MOCHI_BUILD 有值时写进包里的 Info.plist（发布时用标签的版本号），仓库里的不动。
# MOCHI_UPDATE_REPOSITORY（owner/name）换掉检查更新问的 GitHub 仓库，GitHub Actions 里是构建它的那个仓库。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Mochi"

APP="${MOCHI_APP:-build/Mochi.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mochi"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${MOCHI_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MOCHI_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${MOCHI_BUILD:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $MOCHI_BUILD" "$APP/Contents/Info.plist"
fi
if [ -n "${MOCHI_UPDATE_REPOSITORY:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :MochiUpdateRepository $MOCHI_UPDATE_REPOSITORY" "$APP/Contents/Info.plist"
fi
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
