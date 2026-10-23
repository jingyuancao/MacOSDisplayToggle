#!/bin/bash
# 登录项策略回归测试：一条命令，几秒内给出红/绿。
#   红 = 路径判定、状态映射或启动自愈条件有缺陷
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

swiftc -O \
    Sources/LoginItem.swift \
    Tests/LoginItem/main.swift \
    -o build/login_item_test

./build/login_item_test
