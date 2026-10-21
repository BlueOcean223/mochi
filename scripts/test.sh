#!/bin/bash
# 跑单元测试：scripts/test.sh [swift test 的其他参数]。
# 只装了 Command Line Tools 时，SwiftPM 找不到 CLT 自带的 Testing.framework 和它要的 lib_TestingInterop.dylib，
# 要手动给编译、链接和运行时的路径；装了 Xcode 就不用。
set -euo pipefail
cd "$(dirname "$0")/.."

FLAGS=()
DEV="$(xcode-select -p)"
if [[ "$DEV" == *CommandLineTools* ]]; then
  D="$DEV/Library/Developer"
  FLAGS=(-Xswiftc -F -Xswiftc "$D/Frameworks"
         -Xlinker -F -Xlinker "$D/Frameworks"
         -Xlinker -rpath -Xlinker "$D/Frameworks"
         -Xlinker -rpath -Xlinker "$D/usr/lib")
fi
swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
