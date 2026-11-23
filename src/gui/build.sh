#!/bin/sh
# 编译 TSLTV.app（tvOS 原生，无需 Xcode 工程）
set -e
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk
cd "$(dirname "$0")"
rm -rf TSLTV.app
mkdir -p TSLTV.app
clang -target arm64-apple-tvos17.0 -isysroot "$SDK" -fobjc-arc \
      -framework UIKit -framework Foundation \
      -O2 main.m -o TSLTV.app/TSLTV
cp Info.plist TSLTV.app/Info.plist
echo "构建完成: $(pwd)/TSLTV.app"
ls -l TSLTV.app
