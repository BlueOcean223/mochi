#!/bin/bash
# 打印 CHANGELOG.md 里某个版本那一节（不含标题），发版时当 Release 说明：scripts/notes.sh 0.1.3
# 没有这一节、或者这一节是空的就失败，免得发出去一个没有说明的版本。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法：scripts/notes.sh 版本号}"
NOTES="$(awk -v v="$VERSION" '/^## / { p = ($2 == v); next } p' CHANGELOG.md | sed -e '/./,$!d')"
if [ -z "$(echo "$NOTES" | tr -d '[:space:]')" ]; then
  echo "CHANGELOG.md 里没有 $VERSION 这一节" >&2
  exit 1
fi
printf '%s\n' "$NOTES"
