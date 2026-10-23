#!/bin/bash
# 构建 MacOSDisplayToggle.app。
#   ./build.sh            只构建到 build/
#   ./build.sh --install  构建后安装到 /Applications，替换并重启正在运行的旧版本
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacOSDisplayToggle"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"
PLIST="$APP/Contents/Info.plist"

# 版本号唯一来源：Sources/Version.swift；构建号用构建时间
VERSION=$(sed -n 's/.*static let number = "\(.*\)".*/\1/p' Sources/Version.swift)
BUILD=$(date +%Y%m%d%H%M)
if [[ -z "$VERSION" ]]; then
    echo "✗ 无法从 Sources/Version.swift 读取版本号" >&2
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 编译 $APP_NAME v$VERSION (build $BUILD) ..."
swiftc -O Sources/*.swift -o "$BIN"

echo "▸ 写入 Info.plist ..."
cp Info.plist "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

echo "▸ 签名（ad-hoc）..."
codesign --force --sign - "$APP" >/dev/null 2>&1 && echo "  ok" || echo "  签名跳过（不影响本地运行）"

echo "▸ 校验 ..."
"$BIN" status | sed 's/^/  /'

echo ""
echo "构建完成：$(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/$APP_NAME.app"

    # 先退出所有正在运行的实例。按进程名匹配而不是命令行：经
    # /usr/local/bin/macosdisplaytoggle 符号链接启动的实例，argv 里没有 .app 路径，
    # pkill -f 匹配不到，会留下旧实例占着 LaunchServices 的「已运行」登记，导致 open 不启动新版。
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "▸ 退出正在运行的旧版本 ..."
        pkill -x "$APP_NAME" || true
        sleep 1
    fi

    echo "▸ 安装到 $DEST ..."
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"

    echo "▸ 建立命令行入口 /usr/local/bin/macosdisplaytoggle ..."
    if ln -sf "$DEST/Contents/MacOS/$APP_NAME" /usr/local/bin/macosdisplaytoggle 2>/dev/null; then
        echo "  ok：终端里可直接用 macosdisplaytoggle"
    else
        echo "  跳过（/usr/local/bin 不可写，可自行 sudo ln -sf \"$DEST/Contents/MacOS/$APP_NAME\" /usr/local/bin/macosdisplaytoggle）"
    fi

    echo "▸ 启动新版本 ..."
    open "$DEST"
    sleep 2
    if ! pgrep -x "$APP_NAME" >/dev/null; then
        echo "" >&2
        echo "⚠️ 安装完成，但启动后没检测到进程。请手动打开 $DEST，并查看 ~/Library/Logs/MacOSDisplayToggle/events.log" >&2
        exit 1
    fi
    echo ""
    echo "已安装并启动：$("$DEST/Contents/MacOS/$APP_NAME" version)"
fi
