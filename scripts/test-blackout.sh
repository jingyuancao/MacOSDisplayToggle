#!/bin/bash
# 黑屏判定回归测试：一条命令，几秒内给出红/绿。
#   红 = 存在会让用户陷入黑屏的判定缺陷
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

swiftc -O \
    Sources/Version.swift \
    Sources/EventLog.swift \
    Sources/DisplayAPI.swift \
    Sources/BlackoutJudge.swift \
    Sources/DisplayStore.swift \
    Tests/BlackoutJudge/main.swift \
    -o build/blackout_judge_test

./build/blackout_judge_test
