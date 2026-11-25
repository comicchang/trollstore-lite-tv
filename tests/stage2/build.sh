#!/bin/sh
# Stage 2 宿主机侧构建：两个最小测试单元 + 原生容器助手 + 截屏助手。
#
#   ./tests/stage2/build.sh
#
# 产物在 dist/stage2/（不入库）。本脚本不签名、不接触 Apple TV；
# 签名/信任/部署/注册/清理全部是设备侧动作，必须先取得 AGY 的 AUTHORIZED。
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SDK=$(xcrun --sdk appletvos --show-sdk-path 2>/dev/null || true)
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
    SDK=/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk
fi
if [ ! -d "$SDK" ]; then
    echo "SKIP: 未找到 AppleTVOS.sdk"
    exit 2
fi

OUT="$ROOT/dist/stage2"
rm -rf "$OUT"
mkdir -p "$OUT/VerifyProbe.app"

clang_tvos() {
    clang -target arm64-apple-tvos17.0 -isysroot "$SDK" -O2 "$@"
}

echo "== 构建 Stage 2 单元 =="
clang_tvos "$ROOT/tests/stage1/hello-verify.m" -o "$OUT/hello-verify"
clang_tvos -fobjc-arc -framework UIKit -framework Foundation -framework CoreGraphics \
    "$ROOT/tests/stage1/probe-app.m" -o "$OUT/VerifyProbe.app/VerifyProbe"
cp "$ROOT/tests/stage1/ProbeInfo.plist" "$OUT/VerifyProbe.app/Info.plist"
clang_tvos -fobjc-arc -framework Foundation \
    "$ROOT/tests/stage2/tsverify.m" -o "$OUT/tsverify"
clang_tvos -fobjc-arc -framework Foundation -framework CoreGraphics \
    -framework ImageIO -framework IOSurface -framework QuartzCore \
    "$ROOT/tests/stage2/shot.m" -o "$OUT/shot"

echo "== 静态校验（host machocheck） =="
if ! cc -O2 -o "$OUT/machocheck" "$ROOT/src/tools/machocheck.c"; then
    echo "FAIL: machocheck 构建失败"
    exit 1
fi

check_one() {
    label=$1
    bin=$2
    if [ ! -f "$bin" ]; then
        echo "FAIL $label: 产物不存在"
        exit 1
    fi
    info=$("$OUT/machocheck" "$bin" 2>&1)
    case "$info" in
        *"platform=3 minos=17.0 cryptid=0"*)
            echo "PASS $label: $info"
            ;;
        *)
            echo "FAIL $label: 期望 platform=3 minos=17.0 cryptid=0，实际 $info"
            exit 1
            ;;
    esac
}

check_one hello-verify "$OUT/hello-verify"
check_one VerifyProbe "$OUT/VerifyProbe.app/VerifyProbe"
check_one tsverify "$OUT/tsverify"
check_one shot "$OUT/shot"
plutil -lint "$OUT/VerifyProbe.app/Info.plist" >/dev/null

echo "== sha256 =="
shasum -a 256 "$OUT/hello-verify" "$OUT/VerifyProbe.app/VerifyProbe" \
    "$OUT/tsverify" "$OUT/shot" | sed 's#^#  #'
echo
echo "产物目录: $OUT"
