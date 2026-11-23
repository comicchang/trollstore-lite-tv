#!/bin/sh
set -e
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk
cd "$(dirname "$0")"
clang -target arm64-apple-tvos17.0 -isysroot "$SDK" -fobjc-arc \
      -framework Foundation -O2 main.m -o tsltvweb
echo "构建完成: $(pwd)/tsltvweb"
ls -l tsltvweb
