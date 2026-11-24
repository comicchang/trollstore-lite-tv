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

rm -rf "$BUILD"; mkdir -p "$BUILD/Payload/TSLTVDemo.app"
clang -target arm64-apple-tvos17.0 -isysroot "$SDK" -fobjc-arc \
      -framework UIKit -framework Foundation -framework CoreGraphics \
      -O2 "$HERE/main.m" -o "$BUILD/Payload/TSLTVDemo.app/TSLTVDemo"
cp "$HERE/Info.plist" "$BUILD/Payload/TSLTVDemo.app/Info.plist"

# 生成并编译反色风格的 tvOS 图标，避免主屏空白占位
if command -v swift >/dev/null 2>&1; then
  swift "$HERE/make-icon.swift" "$BUILD/Assets.xcassets" >/dev/null 2>&1 || true
  if [ -d "$BUILD/Assets.xcassets" ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    actool --compile "$BUILD/Payload/TSLTVDemo.app" --platform appletvos \
           --minimum-deployment-target 17.0 --target-device tv \
           --app-icon "AppIcon" \
           --output-partial-info-plist "$BUILD/icon.plist" \
           "$BUILD/Assets.xcassets" >/dev/null 2>&1 || echo "警告: demo 图标编译失败"
  fi
fi

mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/TSLTVDemo-unsigned.ipa"   # zip 会追加，必须先删
( cd "$BUILD" && zip -qr "$ROOT/dist/TSLTVDemo-unsigned.ipa" Payload )
rm -rf "$BUILD"
echo "产物: $ROOT/dist/TSLTVDemo-unsigned.ipa"
ls -lh "$ROOT/dist/TSLTVDemo-unsigned.ipa"
