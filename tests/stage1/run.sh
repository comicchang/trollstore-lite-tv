#!/bin/sh
# TrollStore Lite TV —— Stage 1：主机侧静态验证（不接触设备）
#
#   ./tests/stage1/run.sh
#
# 做什么：用 AppleTVOS.sdk 交叉编译两个最小 tvOS 单元（一个 C 程序、一个 ObjC UIKit App），
#         校验 Mach-O 平台/minOS/加密位、Info.plist 关键字段、签名 entitlement，
#         打印环境基线与产物 sha256。全部产物写在 mktemp 目录里，退出即删。
# 不做什么：不 ssh、不安装、不碰 Apple TV、不在 TMP 之外写任何东西。
#
# 退出码：0 全部 PASS / 1 有 FAIL / 2 找不到 AppleTVOS.sdk（SKIP）

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STAGE1="$ROOT/tests/stage1"
TVOS_VERSION=17.0
PASS=0
FAIL=0

ok()    { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; return 0; }
bad()   { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; return 0; }
info()  { printf '  info  %s\n' "$1"; }
group() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------- SDK
SDK=""
if command -v xcrun >/dev/null 2>&1; then
    SDK=$(xcrun --sdk appletvos --show-sdk-path 2>/dev/null) || SDK=""
fi
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
    SDK=/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk
fi
if [ ! -d "$SDK" ]; then
    echo "SKIP: 未找到 AppleTVOS.sdk"
    exit 2
fi

printf 'TrollStore Lite TV —— Stage 1 静态验证（主机侧，不接触设备）\n'
printf '环境: macOS %s / %s\n' "$(sw_vers -productVersion 2>/dev/null)" "$(uname -m)"
printf 'SDK:  %s\n' "$SDK"
printf '目标: arm64-apple-tvos%s\n' "$TVOS_VERSION"
printf 'clang: %s\n' "$(clang --version 2>/dev/null | head -1)"

TMP=$(mktemp -d) || { echo "FAIL: mktemp -d 失败"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

BIN_HELLO="$TMP/hello-verify"
APP="$TMP/VerifyProbe.app"
BIN_PROBE="$APP/VerifyProbe"
PLIST="$APP/Info.plist"

# ---------------------------------------------------------------- 小工具
plist_get() { # <plist> <PlistBuddy 路径>：优先 PlistBuddy，退化到 plutil
    if [ -x /usr/libexec/PlistBuddy ]; then
        /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null
        return $?
    fi
    path=$(printf '%s' "${2#:}" | tr ':' '.')
    plutil -extract "$path" raw -o - "$1" 2>/dev/null
}

version_le() { # <a> <b>：a <= b 返回 0，a > b 返回 1，非版本号返回 2
    va=$1
    vb=$2
    case "$va" in ""|*[!0-9.]*) return 2 ;; esac
    case "$vb" in ""|*[!0-9.]*) return 2 ;; esac
    amaj=${va%%.*}
    bmaj=${vb%%.*}
    [ -n "$amaj" ] || amaj=0
    [ -n "$bmaj" ] || bmaj=0
    amin=${va#*.}
    bmin=${vb#*.}
    [ "$amin" = "$va" ] && amin=0
    [ "$bmin" = "$vb" ] && bmin=0
    amin=${amin%%.*}
    bmin=${bmin%%.*}
    [ -n "$amin" ] || amin=0
    [ -n "$bmin" ] || bmin=0
    [ "$amaj" -lt "$bmaj" ] && return 0
    [ "$amaj" -gt "$bmaj" ] && return 1
    [ "$amin" -le "$bmin" ]
}

check_macho() { # <标签> <二进制>：file 类型 + machocheck 平台/minOS/加密位
    label=$1
    bin=$2
    if [ ! -f "$bin" ]; then
        bad "$label: 产物不存在（编译失败）"
        return 0
    fi
    desc=$(file -b "$bin" 2>/dev/null)
    case "$desc" in
        *Mach-O*arm64*executable*|*Mach-O*executable*arm64*)
            ok "$label: file → $desc" ;;
        *)
            bad "$label: 不是 arm64 Mach-O 可执行文件（file: ${desc:-<无输出>}）" ;;
    esac
    if [ ! -x "$TMP/machocheck" ]; then
        bad "$label: machocheck 不可用，无法校验 platform/minos/cryptid"
        return 0
    fi
    want="platform=3 minos=$TVOS_VERSION cryptid=0"
    out=$("$TMP/machocheck" "$bin" 2>&1)
    case "$out" in
        *"$want"*)
            ok "$label: $(printf '%s' "$out" | head -1)" ;;
        *)
            bad "$label: 期望 $want，实际 $(printf '%s' "$out" | head -1)" ;;
    esac
    return 0
}

check_entitlements() { # <标签> <二进制>：只对 entitlement/cryptid 判失败，签名状态仅报告
    label=$1
    bin=$2
    if [ ! -f "$bin" ]; then
        bad "$label: entitlement 检查（产物不存在）"
        return 0
    fi
    sig=$(codesign -dv "$bin" 2>&1)
    sig_state=unsigned
    case "$sig" in
        *"not signed at all"*)
            sig_state=unsigned ;;
        *"Signature=adhoc"*)
            sig_state="ad-hoc" ;;
        "")
            sig_state=unknown ;;
        *)
            sigline=$(printf '%s\n' "$sig" | sed -n 's/^Signature=//p' | head -1)
            if [ -n "$sigline" ]; then
                sig_state="signed($sigline)"
            else
                sig_state=signed
            fi
            ;;
    esac
    info "$label: 签名状态=$sig_state"
    ent=$(codesign -d --entitlements :- "$bin" 2>/dev/null)
    case "$ent" in
        *"<key"*)
            bad "$label: 带 entitlement 键（Static 单元不应有）" ;;
        *)
            ok "$label: 无 entitlement 键" ;;
    esac
    return 0
}

check_plist_eq() { # <PlistBuddy 路径> <期望值> <描述>
    got=$(plist_get "$PLIST" "$1")
    if [ "$got" = "$2" ]; then
        ok "$3 = $2"
    else
        bad "$3：期望 $2，实际 ${got:-<空>}"
    fi
}

# ---------------------------------------------------------------- 构建
group "构建（主机 cc + 交叉 clang）"
if cc -O2 -o "$TMP/machocheck" "$ROOT/src/tools/machocheck.c" 2>"$TMP/build-machocheck.log"; then
    ok "构建 machocheck（主机 cc -O2）"
else
    bad "构建 machocheck（主机 cc -O2）"
    sed -n '1,6p' "$TMP/build-machocheck.log" | sed 's/^/        /'
fi

mkdir -p "$APP"

build_tvos() { # <产物> <源文件> [额外编译参数...]
    out=$1
    src=$2
    shift 2
    if clang -target "arm64-apple-tvos$TVOS_VERSION" -isysroot "$SDK" -O2 "$@" \
            -o "$out" "$src" 2>"$TMP/build.log"; then
        ok "编译 $(basename "$src") → $(basename "$out")"
        return 0
    fi
    bad "编译 $(basename "$src") → $(basename "$out")"
    sed -n '1,8p' "$TMP/build.log" | sed 's/^/        /'
    return 1
}

build_tvos "$BIN_HELLO" "$STAGE1/hello-verify.m"
build_tvos "$BIN_PROBE" "$STAGE1/probe-app.m" -fobjc-arc -framework UIKit -framework Foundation -framework CoreGraphics

if cp "$STAGE1/ProbeInfo.plist" "$PLIST" 2>"$TMP/build.log"; then
    ok "ProbeInfo.plist → VerifyProbe.app/Info.plist"
else
    bad "拷贝 ProbeInfo.plist 到 bundle"
    sed -n '1,4p' "$TMP/build.log" | sed 's/^/        /'
fi

# ---------------------------------------------------------------- sha256
group "产物 sha256"
if [ -f "$BIN_HELLO" ]; then
    info "hello-verify: $(shasum -a 256 "$BIN_HELLO" | awk '{print $1}')"
else
    info "hello-verify: <未构建>"
fi
if [ -f "$BIN_PROBE" ]; then
    info "VerifyProbe:  $(shasum -a 256 "$BIN_PROBE" | awk '{print $1}')"
else
    info "VerifyProbe:  <未构建>"
fi

# ---------------------------------------------------------------- 单元 A
group "单元 A：hello-verify（C，无 UI）"
check_macho "hello-verify" "$BIN_HELLO"
check_entitlements "hello-verify" "$BIN_HELLO"

# ---------------------------------------------------------------- 单元 B
group "单元 B：VerifyProbe（ObjC/UIKit）"
check_macho "VerifyProbe" "$BIN_PROBE"
check_entitlements "VerifyProbe" "$BIN_PROBE"

# ---------------------------------------------------------------- Info.plist
group "Info.plist（VerifyProbe.app）"
check_plist_eq ":CFBundleIdentifier" com.tsltv.verify.probe "CFBundleIdentifier"
check_plist_eq ":CFBundleExecutable" VerifyProbe "CFBundleExecutable"
if [ -f "$BIN_PROBE" ] && [ -x "$BIN_PROBE" ]; then
    ok "bundle 内存在可执行文件 VerifyProbe"
else
    bad "bundle 内缺少可执行文件 VerifyProbe"
fi
check_plist_eq ":CFBundleSupportedPlatforms:0" AppleTVOS "CFBundleSupportedPlatforms[0]"
minos=$(plist_get "$PLIST" ":MinimumOSVersion")
if [ -z "$minos" ]; then
    bad "MinimumOSVersion 缺失"
elif version_le "$minos" "$TVOS_VERSION"; then
    ok "MinimumOSVersion=$minos <= $TVOS_VERSION"
else
    bad "MinimumOSVersion=$minos 不满足 <= $TVOS_VERSION"
fi
check_plist_eq ":CFBundlePackageType" APPL "CFBundlePackageType"

# ---------------------------------------------------------------- 汇总
printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1