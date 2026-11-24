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

# machoscan: 单进程快速扫描目录下的全部 Mach-O 文件（避免 shell 逐文件 fork）
[ -f machoscan.c ] && clang -target arm64-apple-tvos17.0 -isysroot "$SDK" -O2 \
    machoscan.c -o machoscan

ls -l machocheck wake modinject machoscan 2>/dev/null || true
