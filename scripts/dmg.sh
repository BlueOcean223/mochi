#!/bin/bash
# 把 Mochi.app 装进 dmg：scripts/dmg.sh build/Mochi.app build/Mochi-0.2.0.dmg
# 打开后窗口里是 Mochi 和「应用程序」的替身，把 Mochi 拖过去就装好了。只用系统的 hdiutil。
set -euo pipefail
APP="$1"
DMG="$2"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Mochi.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
# GitHub Actions 的机器上 hdiutil 偶尔报 Resource busy，隔几秒重试。
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname Mochi -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null; then
    echo "$DMG"
    exit 0
  fi
  echo "hdiutil create 失败（第 $attempt 次），重试" >&2
  sleep 5
done
exit 1
