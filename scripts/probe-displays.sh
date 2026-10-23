#!/bin/bash
# 只读显示探针，用于复现「关内屏 + 拔线」时观察各路信号。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

swiftc -O \
    Sources/Version.swift \
    Sources/EventLog.swift \
    Sources/DisplayAPI.swift \
    Sources/BlackoutJudge.swift \
    Sources/DisplayStore.swift \
    debug/DisplayProbe/main.swift \
    -o build/display_probe

exec ./build/display_probe
