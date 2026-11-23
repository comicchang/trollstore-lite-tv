#!/bin/sh
# 构建无签名的 demo ipa（用来验证安装链路；也可以自己改造成你的应用模板）
#
#   ./examples/hello-tvos/build.sh          → dist/TSLTVDemo-unsigned.ipa
#
# 产物是**未签名**的：签名由安装器在设备上完成（ad-hoc + 内核信任缓存）。
set -eu
SDK=$(xcrun --sdk appletvos --show-sdk-path 2>/dev/null || \
      echo /Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BUILD="$HERE/.build"

rm -rf "$BUILD"; mkdir -p "$BUILD/Payload/TrollStoreLiteTVDemo.app"
clang -target arm64-apple-tvos17.0 -isysroot "$SDK" -fobjc-arc \
      -framework UIKit -framework Foundation -framework CoreGraphics \
      -O2 "$HERE/main.m" -o "$BUILD/Payload/TrollStoreLiteTVDemo.app/TrollStoreLiteTVDemo"
cp "$HERE/Info.plist" "$BUILD/Payload/TrollStoreLiteTVDemo.app/Info.plist"

mkdir -p "$ROOT/dist"
( cd "$BUILD" && zip -qr "$ROOT/dist/TSLTVDemo-unsigned.ipa" Payload )
rm -rf "$BUILD"
echo "产物: $ROOT/dist/TSLTVDemo-unsigned.ipa"
ls -lh "$ROOT/dist/TSLTVDemo-unsigned.ipa"
