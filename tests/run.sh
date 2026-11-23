#!/bin/sh
# TrollStore Lite TV —— 不需要设备的测试
#
#   ./tests/run.sh            # 全部跑一遍
#   ./tests/run.sh -v         # 打印每条断言
#
# 覆盖：脚本语法、plist 合法性、参数与用法、命令注入拦截、Mach-O 解析、
#       安装前判定（加密包 / iOS 包 / minOS）、demo ipa 产物结构。
# 需要设备的端到端验收在 scripts/accept.sh。

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLI="$ROOT/src/cli/tsltv"
VERBOSE=${1:-}
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok()   { PASS=$((PASS+1)); [ "$VERBOSE" = "-v" ] && printf '  ✓ %s\n' "$1"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; return 0; }
group(){ printf '\n== %s ==\n' "$1"; }

expect_rc() { # <期望码> <描述> <命令...>
  want=$1; desc=$2; shift 2
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then ok "$desc (rc=$rc)"; else
    bad "${desc}：期望 rc=${want}，实际 rc=$rc"
    printf '    输出: %s\n' "$(printf '%s' "$out" | head -3)"
  fi
}

# ---------------------------------------------------------------- 1. 语法
group "脚本语法"
for f in "$CLI" "$ROOT/src/daemon/tsltvd" "$ROOT/src/daemon/retrust.sh" \
         "$ROOT/src/fork/tsh" "$ROOT"/scripts/*.sh "$ROOT"/src/*/build.sh; do
  [ -f "$f" ] || continue
  if sh -n "$f" 2>/dev/null; then ok "语法 $(basename "$f")"; else bad "语法 $(basename "$f")"; fi
done

# ---------------------------------------------------------------- 2. plist
group "plist 合法性"
if command -v plutil >/dev/null 2>&1; then
  for f in "$ROOT"/src/daemon/*.plist "$ROOT"/src/gui/Info.plist "$ROOT"/examples/hello-tvos/Info.plist; do
    [ -f "$f" ] || continue
    if plutil -lint "$f" >/dev/null 2>&1; then ok "plist $(basename "$f")"; else bad "plist $(basename "$f")"; fi
  done
elif command -v python3 >/dev/null 2>&1; then
  for f in "$ROOT"/src/daemon/*.plist "$ROOT"/src/gui/Info.plist "$ROOT"/examples/hello-tvos/Info.plist; do
    [ -f "$f" ] || continue
    if python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$f" 2>/dev/null; then
      ok "plist $(basename "$f")"
    else
      bad "plist $(basename "$f")"
    fi
  done
else
  ok "跳过 plist 校验（无 plutil / python3）"
fi

# ---------------------------------------------------------------- 3. 用法与参数
group "CLI 用法与参数"
expect_rc 0 "version 无参数" "$CLI" version
v=$("$CLI" version 2>/dev/null)
case "$v" in
  [0-9]*.[0-9]*.[0-9]*) ok "版本号格式 ($v)" ;;
  *) bad "版本号格式异常: $v" ;;
esac
expect_rc 1 "install 缺参数" "$CLI" install
expect_rc 1 "未知子命令" "$CLI" nosuchcommand

# ---------------------------------------------------------------- 4. 注入拦截
group "命令注入拦截"
expect_rc 1 "remote 拒绝分号" "$CLI" remote 'list; rm -rf /'
expect_rc 1 "remote 拒绝管道" "$CLI" remote 'list | cat'
expect_rc 1 "remote 拒绝反引号" "$CLI" remote 'list `id`'

# ---------------------------------------------------------------- 5. 预检判定
group "安装前判定（纯函数）"
verdict_case() { # <探测串> <期望rc> <描述>
  out=$(TrollStoreLiteTV_LIB_ONLY=1 sh -c ". \"$CLI\"; precheck_verdict \"\$1\"" sh "$1" 2>&1)
  rc=$?
  if [ "$rc" = "$2" ]; then ok "$3"; else bad "$3：期望 rc=$2 实际 rc=$rc"; fi
}
verdict_case "platform=3 minos=17.0 cryptid=0" 0 "未加密 tvOS 包 → 放行"
verdict_case "platform=3 minos=17.0 cryptid=1" 1 "加密包 → 拒绝"
verdict_case "platform=2 minos=15.0 cryptid=0" 0 "iOS 包 → 放行但警告"
verdict_case "platform=3 minos=18.0 cryptid=0" 0 "高 minOS → 放行但警告"

warn=$(TrollStoreLiteTV_LIB_ONLY=1 sh -c ". \"$CLI\"; precheck_verdict 'platform=2 minos=15.0 cryptid=0'" 2>&1)
case "$warn" in *"iOS 平台"*) ok "iOS 警告文案出现" ;; *) bad "缺少 iOS 平台警告" ;; esac
warn=$(TrollStoreLiteTV_LIB_ONLY=1 sh -c ". \"$CLI\"; precheck_verdict 'platform=3 minos=18.0 cryptid=0'" 2>&1)
case "$warn" in *"高于本机"*) ok "minOS 警告文案出现" ;; *) bad "缺少 minOS 警告" ;; esac

# ---------------------------------------------------------------- 6. Mach-O 解析
group "Mach-O 解析"
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk
if [ -d "$SDK" ]; then
  cat > "$TMP/t.m" <<'EOF'
int main(void){ return 0; }
EOF
  if clang -target arm64-apple-tvos17.0 -isysroot "$SDK" "$TMP/t.m" -o "$TMP/probe" 2>/dev/null; then
    info=$(TrollStoreLiteTV_LIB_ONLY=1 sh -c ". \"$CLI\"; macho_info \"\$1\"" sh "$TMP/probe" 2>&1)
    case "$info" in
      *platform=3*minos=17.0*cryptid=0*) ok "解析结果: $info" ;;
      *) bad "解析异常: $info" ;;
    esac
  else
    bad "无法编译 tvOS 测试二进制"
  fi
else
  ok "跳过 Mach-O 解析（无 tvOS SDK）"
fi

# ---------------------------------------------------------------- 7. demo ipa
group "demo ipa 产物"
if [ -d "$SDK" ]; then
  if sh "$ROOT/examples/hello-tvos/build.sh" >/dev/null 2>&1; then
    IPA="$ROOT/dist/TrollStoreLiteTVDemo-unsigned.ipa"
    if [ -f "$IPA" ]; then
      ok "生成 $(basename "$IPA")"
      listing=$(unzip -l "$IPA" 2>/dev/null | awk '{print $4}')
      case "$listing" in *Payload/TrollStoreLiteTVDemo.app/Info.plist*) ok "包含 Payload/TrollStoreLiteTVDemo.app/Info.plist" ;; *) bad "ipa 结构不对" ;; esac
      case "$listing" in *Payload/TrollStoreLiteTVDemo.app/TrollStoreLiteTVDemo*) ok "包含主可执行" ;; *) bad "缺主可执行" ;; esac
      # 必须是未签名的
      if command -v codesign >/dev/null 2>&1; then
        if codesign -dv "$IPA" >/dev/null 2>&1; then bad "ipa 竟然带签名（应未签名）"; else ok "确认未签名"; fi
      fi
    else
      bad "未生成 demo ipa"
    fi
  else
    bad "demo 构建失败"
  fi
else
  ok "跳过 demo 构建（无 tvOS SDK）"
fi

# ---------------------------------------------------------------- 汇总
printf '\n----------------------------------------\n'
printf 'PASS %d / FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "全部通过 ✅"
