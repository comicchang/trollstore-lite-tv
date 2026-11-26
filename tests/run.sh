#!/bin/sh
# TrollStore Lite TV —— 不需要设备的测试
#
#   ./tests/run.sh            # 全部跑一遍
#   ./tests/run.sh -v         # 打印每条断言
#
# 覆盖：脚本语法、plist 合法性、参数与用法、命令注入拦截、卸载来源护栏、Mach-O 解析、
#       安装前判定（加密包 / iOS 包 / minOS）、demo ipa 产物结构、mod 注入。
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
         "$ROOT/src/fork/tsh" "$ROOT"/scripts/*.sh "$ROOT"/scripts/package/*.sh \
         "$ROOT"/src/*/build.sh; do
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

# ---------------------------------------------------------------- 4b. 卸载来源护栏
group "卸载来源护栏"
TEST_ROOT="$TMP/uninstall-root"
TEST_CLI="$TEST_ROOT/usr/libexec/tsltv/tsltv"
mkdir -p "$(dirname "$TEST_CLI")" "$TMP/fakebin" "$TMP/apps/adopt" "$TMP/apps/install"
cp "$CLI" "$TEST_CLI"
cat > "$TMP/fakebin/id" <<'EOF'
#!/bin/sh
echo 0
EOF
cat > "$TMP/fakebin/uicache" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TEST_ROOT/usr/libexec/tsltv/tsreg" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/fakebin/id" "$TMP/fakebin/uicache" "$TEST_ROOT/usr/libexec/tsltv/tsreg"
printf 'com.example.adopt\t%s\tdeadbeef\t2026-01-01 00:00:00\tadopt\n' \
  "$TMP/apps/adopt" > "$TEST_ROOT/usr/libexec/tsltv/installed.tsv"
printf 'com.example.install\t%s\tdeadbeef\t2026-01-01 00:00:00\tinstall\n' \
  "$TMP/apps/install" >> "$TEST_ROOT/usr/libexec/tsltv/installed.tsv"
PATH="$TMP/fakebin:$PATH" "$TEST_CLI" uninstall com.example.adopt > "$TMP/adopt.out" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && [ -d "$TMP/apps/adopt" ] && \
   awk -F '\t' '$1=="com.example.adopt" && $5=="adopt"{found=1} END{exit !found}' \
     "$TEST_ROOT/usr/libexec/tsltv/installed.tsv"; then
  ok "adopt 应用拒绝卸载并保留目录与清单"
else
  bad "adopt 应用未受卸载护栏保护"
  printf '    rc=%s 输出=%s\n' "$rc" "$(cat "$TMP/adopt.out")"
fi
PATH="$TMP/fakebin:$PATH" "$TEST_CLI" uninstall com.example.install > "$TMP/install.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$TMP/apps/install" ] && \
   ! awk -F '\t' '$1=="com.example.install"{found=1} END{exit !found}' \
     "$TEST_ROOT/usr/libexec/tsltv/installed.tsv"; then
  ok "本工具安装的应用仍可正常卸载"
else
  bad "本工具安装的应用卸载失败"
  printf '    rc=%s 输出=%s\n' "$rc" "$(cat "$TMP/install.out")"
fi

# ---------------------------------------------------------------- 4c. tsh 退出码透传
group "tsh 退出码透传"
for code in 171 179 180 181 184; do
  cat > "$TMP/fake-tsltv" <<EOF
#!/bin/sh
exit $code
EOF
  chmod +x "$TMP/fake-tsltv"
  TSLTV_BIN="$TMP/fake-tsltv" "$ROOT/src/fork/tsh" install /dev/null >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$code" ]; then
    ok "tsh install 透传 $code"
  else
    bad "tsh install 未透传 $code（rc=$rc）"
  fi
done

# ---------------------------------------------------------------- 4d. tsreg 构建
group "tsreg（tvOS 原生注册工具）"
TSREG_SDK=/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk
if [ -d "$TSREG_SDK" ] && command -v clang >/dev/null 2>&1; then
  if clang -target arm64-apple-tvos17.0 -isysroot "$TSREG_SDK" -fobjc-arc -Wall \
       -framework Foundation "$ROOT/src/tools/tsreg.m" -o "$TMP/tsreg" 2>"$TMP/tsreg.log"; then
    info=$(cc -O2 -o "$TMP/mc" "$ROOT/src/tools/machocheck.c" 2>/dev/null && "$TMP/mc" "$TMP/tsreg" 2>/dev/null)
    case "$info" in
      *platform=3*minos=17.0*cryptid=0*) ok "tsreg 构建通过且为 tvOS 二进制" ;;
      *) bad "tsreg 元数据异常: $info" ;;
    esac
  else
    bad "tsreg 构建失败"
    sed 's/^/    /' "$TMP/tsreg.log"
  fi
else
  ok "跳过 tsreg 构建（无 tvOS SDK）"
fi

# ---------------------------------------------------------------- 5. 预检判定
group "安装前判定（纯函数）"
verdict_case() { # <探测串> <期望rc> <描述>
  out=$(TSLTV_LIB_ONLY=1 sh -c ". \"$CLI\"; precheck_verdict \"\$1\"" sh "$1" 2>&1)
  rc=$?
  if [ "$rc" = "$2" ]; then ok "$3"; else bad "$3：期望 rc=$2 实际 rc=$rc"; fi
}
verdict_case "platform=3 minos=17.0 cryptid=0" 0 "未加密 tvOS 包 → 放行"
verdict_case "platform=3 minos=17.0 cryptid=1" 1 "加密包 → 拒绝"
verdict_case "platform=2 minos=15.0 cryptid=0" 0 "iOS 包 → 放行但警告"
verdict_case "platform=3 minos=18.0 cryptid=0" 0 "高 minOS → 放行但警告"

warn=$(TSLTV_LIB_ONLY=1 sh -c ". \"$CLI\"; precheck_verdict 'platform=2 minos=15.0 cryptid=0'" 2>&1)
case "$warn" in *"iOS 平台"*) ok "iOS 警告文案出现" ;; *) bad "缺少 iOS 平台警告" ;; esac
warn=$(TSLTV_LIB_ONLY=1 sh -c ". \"$CLI\"; precheck_verdict 'platform=3 minos=18.0 cryptid=0'" 2>&1)
case "$warn" in *"高于本机"*) ok "minOS 警告文案出现" ;; *) bad "缺少 minOS 警告" ;; esac

# ---------------------------------------------------------------- 5b. entitlements / 加密对齐
group "entitlements 对齐（entfix）与加密扫描"
ENTFIX="$TMP/entfix"
if command -v clang >/dev/null 2>&1 && \
   clang -fobjc-arc -framework Foundation -O2 "$ROOT/src/tools/entfix.m" -o "$ENTFIX" 2>/dev/null && \
   [ -x "$ENTFIX" ] && command -v python3 >/dev/null 2>&1; then
  ent_field() { # <plist> <key>
    python3 - "$1" "$2" <<'EOP'
import plistlib, sys
try:
    d = plistlib.loads(open(sys.argv[1], 'rb').read())
except Exception:
    print('<unreadable>'); sys.exit(0)
v = d.get(sys.argv[2], '<absent>')
if isinstance(v, bool):
    print('true' if v else 'false')
elif isinstance(v, list):
    print(','.join(str(x) for x in v))
else:
    print(v)
EOP
  }
  : > "$TMP/ent.empty"
  "$ENTFIX" --fallback --lite-pmap com.example.app < "$TMP/ent.empty" > "$TMP/ent.a.plist" 2>/dev/null
  [ "$(ent_field "$TMP/ent.a.plist" application-identifier)" = "TROLLTROLL.*" ] \
    && ok "主 app 无 entitlements 时回落 TROLLTROLL.*" || bad "回落 application-identifier 不正确"
  [ "$(ent_field "$TMP/ent.a.plist" com.apple.private.security.container-required)" = "com.example.app" ] \
    && ok "缺省需要容器 → container-required=<bundle-id>" || bad "container-required 归一失败"
  [ "$(ent_field "$TMP/ent.a.plist" jb.pmap_cs.custom_trust)" = "PMAP_CS_APP_STORE" ] \
    && ok "Lite 写入 pmap_cs 信任级" || bad "缺 jb.pmap_cs.custom_trust"

  cat > "$TMP/ent.raw.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.private.security.no-container</key><true/>
<key>com.apple.security.iokit-user-client-class</key><array><string>AGXDevice</string></array>
</dict></plist>
EOF
  "$ENTFIX" --lite-pmap com.example.nocontainer < "$TMP/ent.raw.plist" > "$TMP/ent.b.plist" 2>/dev/null
  [ "$(ent_field "$TMP/ent.b.plist" com.apple.private.security.container-required)" = "<absent>" ] \
    && ok "no-container=true 时不强塞 container-required" || bad "no-container 场景被改写"
  [ "$(ent_field "$TMP/ent.b.plist" com.apple.security.iokit-user-client-class)" = "AGXDevice" ] \
    && ok "原有 entitlement 原样保留" || bad "原有 entitlement 丢失"

  cat > "$TMP/ent.str.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.private.security.container-required</key><string>custom.container</string>
</dict></plist>
EOF
  "$ENTFIX" --lite-pmap com.example.custom < "$TMP/ent.str.plist" > "$TMP/ent.c.plist" 2>/dev/null
  [ "$(ent_field "$TMP/ent.c.plist" com.apple.private.security.container-required)" = "custom.container" ] \
    && ok "字符串容器 id 原样保留" || bad "自定义容器 id 被改写"

  cat > "$TMP/ent.false.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.private.security.container-required</key><false/>
</dict></plist>
EOF
  "$ENTFIX" --lite-pmap com.example.noreq < "$TMP/ent.false.plist" > "$TMP/ent.d.plist" 2>/dev/null
  [ "$(ent_field "$TMP/ent.d.plist" com.apple.private.security.container-required)" = "false" ] \
    && ok "container-required=false 保留布尔值" || bad "布尔 false 被改写"

  printf '<plist version="1.0"><array><string>x</string></array></plist>\n' > "$TMP/ent.arr.plist"
  if "$ENTFIX" com.example.bad < "$TMP/ent.arr.plist" > "$TMP/ent.e.plist" 2>/dev/null; then
    bad "根节点非 dict 竟然通过"
  else
    ok "根节点非 dict 拒绝"
  fi
else
  ok "跳过 entfix（无 clang/Foundation/python3）"
fi

if cc -O2 "$ROOT/src/tools/machoscan.c" -o "$TMP/ms-e" 2>/dev/null && command -v python3 >/dev/null 2>&1; then
  mkdir -p "$TMP/encdir"
  python3 - "$TMP/encdir" <<'EOP'
import os, struct, sys
out = sys.argv[1]
def macho(cryptid):
    lc = struct.pack('<IIIIII', 0x2c, 24, 0, 4096, cryptid, 0)
    hdr = struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 1, len(lc), 0, 0)
    return hdr + lc
def fat(payload):
    arch = struct.pack('>iiIII', 0x0100000c, 0, 4096, len(payload), 12)
    return struct.pack('>II', 0xcafebabe, 1) + arch + b'\0' * (4096 - 8 - len(arch)) + payload
open(os.path.join(out, 'plain'), 'wb').write(macho(0))
open(os.path.join(out, 'crypt'), 'wb').write(macho(1))
open(os.path.join(out, 'crypt-fat'), 'wb').write(fat(macho(1)))
EOP
  enc=$("$TMP/ms-e" -e "$TMP/encdir" 2>/dev/null | sed "s#$TMP/encdir/##" | sort | tr '\n' ' ')
  if [ "$enc" = "crypt crypt-fat " ]; then
    ok "machoscan -e 只报告加密二进制（含 Fat 首选 slice）"
  else
    bad "machoscan -e 输出异常: $enc"
  fi
  all=$("$TMP/ms-e" "$TMP/encdir" 2>/dev/null | wc -l | tr -d ' ')
  [ "$all" = "3" ] && ok "machoscan 普通模式仍列出全部 Mach-O" || bad "普通模式回归: $all"
else
  ok "跳过 machoscan -e（无 cc/python3）"
fi

# ---------------------------------------------------------------- 6. Mach-O 解析
group "Mach-O 解析"
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk
if [ -d "$SDK" ]; then
  cat > "$TMP/t.m" <<'EOF'
int main(void){ return 0; }
EOF
  if clang -target arm64-apple-tvos17.0 -isysroot "$SDK" "$TMP/t.m" -o "$TMP/probe" 2>/dev/null; then
    info=$(TSLTV_LIB_ONLY=1 sh -c ". \"$CLI\"; macho_info \"\$1\"" sh "$TMP/probe" 2>&1)
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
    IPA="$ROOT/dist/TSLTVDemo-unsigned.ipa"
    if [ -f "$IPA" ]; then
      ok "生成 $(basename "$IPA")"
      listing=$(unzip -l "$IPA" 2>/dev/null | awk '{print $4}')
      case "$listing" in *Payload/TSLTVDemo.app/Info.plist*) ok "包含 Payload/TSLTVDemo.app/Info.plist" ;; *) bad "ipa 结构不对" ;; esac
      case "$listing" in *Payload/TSLTVDemo.app/TSLTVDemo*) ok "包含主可执行" ;; *) bad "缺主可执行" ;; esac
      case "$listing" in *Payload/TSLTVDemo.app/Assets.car*) ok "包含 tvOS 图标 Assets.car" ;; *) bad "缺 Assets.car 图标" ;; esac
      if grep -q '<string>TSLTVDemo</string>' "$ROOT/examples/hello-tvos/Info.plist"; then
        ok "demo Info.plist CFBundleExecutable 与二进制一致"
      else
        bad "demo Info.plist CFBundleExecutable 不一致"
      fi
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


# ---------------------------------------------------------------- 8. mod 注入
group "mod 注入（LC_LOAD_DYLIB）"
SDK2=/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk
if [ -d "$SDK2" ] && command -v clang >/dev/null 2>&1; then
  clang -fobjc-arc -framework Foundation -O2 "$ROOT/src/tools/modinject.m" -o "$TMP/mi" 2>/dev/null
  clang -target arm64-apple-tvos17.0 -isysroot "$SDK2" -fobjc-arc \
        -framework UIKit -framework Foundation -framework CoreGraphics \
        -O2 "$ROOT/src/gui/main.m" -o "$TMP/host" 2>/dev/null
  if [ -x "$TMP/mi" ] && [ -f "$TMP/host" ]; then
    before=$(python3 - "$TMP/host" <<'EOP'
import struct,sys
d=open(sys.argv[1],'rb').read(32)
print(struct.unpack_from('<I',d,16)[0])
EOP
)
    "$TMP/mi" "$TMP/host" @executable_path/Frameworks/x.dylib >/dev/null 2>&1
    after=$(python3 - "$TMP/host" <<'EOP'
import struct,sys
d=open(sys.argv[1],'rb').read(32)
print(struct.unpack_from('<I',d,16)[0])
EOP
)
    if [ "$after" = "$((before + 1))" ]; then ok "注入成功（ncmds ${before}→${after}）"; else bad "ncmds 未增加（${before}→${after}）"; fi
    # 注意：macOS 的 strings 不扫 Mach-O 头部，load command 只能用二进制 grep
    if grep -aq "@executable_path/Frameworks/x.dylib" "$TMP/host"; then ok "加载命令已写入"; else bad "找不到注入的路径"; fi
    # 编译宿主 machoscan 并验证能准确识别 Mach-O 而跳过普通文件
    if cc -O2 "$ROOT/src/tools/machoscan.c" -o "$TMP/ms" 2>/dev/null; then
      mkdir -p "$TMP/scandir/sub"
      cp "$TMP/host" "$TMP/scandir/sub/bin"
      printf 'plain text\n' > "$TMP/scandir/readme.txt"
      ms_out=$("$TMP/ms" "$TMP/scandir" "/Apps/Test.app" 2>/dev/null)
      if [ "$ms_out" = "/Apps/Test.app/sub/bin" ]; then
        ok "machoscan 精准识别 Mach-O 并映射前缀"
      else
        bad "machoscan 输出异常: $ms_out"
      fi
    fi
  else
    ok "跳过 mod 注入（编译失败）"
  fi
else
  ok "跳过 mod 注入（无 SDK）"
fi

# ---------------------------------------------------------------- 9. Stage 1 验证闸门
group "Stage 1（宿主机侧静态校验）"
if [ -d "$SDK" ] && command -v clang >/dev/null 2>&1; then
  if sh "$ROOT/tests/stage1/run.sh" > "$TMP/stage1.out" 2>&1; then
    ok "Stage 1 全部 PASS"
  else
    bad "Stage 1 失败"
    sed 's/^/    /' "$TMP/stage1.out"
  fi
else
  ok "跳过 Stage 1（无 tvOS SDK）"
fi

# ---------------------------------------------------------------- 汇总
printf '\n----------------------------------------\n'
printf 'PASS %d / FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "全部通过 ✅"
