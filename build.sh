#!/bin/bash
# 编译 OpenDisplay iOS 12 接收端并打成 ipa（临时签名，需要越狱设备上装有 AppSync Unified）。
#   ./build.sh            只编译
#   ./build.sh install    编译后通过 USB 安装到已连接的设备
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
APP=build/Payload/OpenDisplay12.app

rm -rf build
mkdir -p "$APP"

xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=12.2 -isysroot "$SDK" \
    -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
    -framework UIKit -framework Foundation -framework AVFoundation \
    -framework CoreMedia -framework QuartzCore -framework CoreGraphics \
    src/*.m -o "$APP/OpenDisplay12"

cp Info.plist "$APP/Info.plist"
cp icons/*.png "$APP/"
plutil -convert binary1 "$APP/Info.plist"
codesign -f -s - --timestamp=none "$APP"

(cd build && zip -qr OpenDisplay12.ipa Payload)
echo "已生成 build/OpenDisplay12.ipa"

if [[ "${1:-}" == "install" ]]; then
    ideviceinstaller install build/OpenDisplay12.ipa
fi
