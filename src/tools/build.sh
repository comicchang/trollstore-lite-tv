#!/bin/sh
# 编译本目录的 tvOS 小工具（纯 C / ObjC，不依赖被禁 API）
set -e
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk
cd "$(dirname "$0")"

# machocheck: 读 Mach-O 头（备用，安装流程现在用 shell 内 od 解析）
[ -f machocheck.c ] && clang -target arm64-apple-tvos17.0 -isysroot "$SDK" -O2 machocheck.c -o machocheck

# wake: 注入一次 HID 按键，把休眠的电视唤醒（uiopen 在无显示时是空转的）
[ -f wake.m ] && clang -target arm64-apple-tvos17.0 -isysroot "$SDK" -fobjc-arc \
    -framework Foundation wake.m -o wake

# modinject: 向 Mach-O 插入 LC_LOAD_DYLIB（mods apply 用）
[ -f modinject.m ] && clang -target arm64-apple-tvos17.0 -isysroot "$SDK" -fobjc-arc \
    -framework Foundation modinject.m -o modinject

ls -l machocheck wake modinject 2>/dev/null || true
