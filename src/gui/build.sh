#!/bin/sh
# 编译 TrollStoreLiteTV.app（tvOS 原生，无需 Xcode 工程）
set -e
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk
cd "$(dirname "$0")"
rm -rf TrollStoreLiteTV.app
mkdir -p TrollStoreLiteTV.app
clang -target arm64-apple-tvos17.0 -isysroot "$SDK" -fobjc-arc \
      -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
      -O2 main.m -o TrollStoreLiteTV.app/TrollStoreLiteTV
cp Info.plist TrollStoreLiteTV.app/Info.plist

# 图标：tvOS 的图标来自 brandassets，必须编成 Assets.car
if [ -d Assets.xcassets ]; then
  if [ ! -f "Assets.xcassets/App Icon & Top Shelf Image.brandassets/App Icon - Small.imagestack/Back.imagestacklayer/Content.imageset/Back.png" ]; then
    swift make-icon.swift >/dev/null 2>&1 || echo "警告: 图标素材生成失败"
  fi
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  actool --compile TrollStoreLiteTV.app --platform appletvos \
         --minimum-deployment-target 17.0 --target-device tv \
         --app-icon "App Icon & Top Shelf Image" \
         --output-partial-info-plist .icon.plist \
         Assets.xcassets >/dev/null 2>&1 \
    && echo "图标: Assets.car $(du -h TrollStoreLiteTV.app/Assets.car | cut -f1)" \
    || echo "警告: actool 失败，主屏可能没有图标"
  rm -f .icon.plist
fi
echo "构建完成: $(pwd)/TrollStoreLiteTV.app"
ls -l TrollStoreLiteTV.app
