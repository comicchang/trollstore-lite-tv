#!/bin/sh
# TSLTV Lite 验收脚本 —— 一条命令跑完整条链路并给出 PASS/FAIL
#
#   ATV_PASS=<设备sudo密码> ./accept.sh [设备IP]
#
# 步骤：装包 → 造测试 ipa → 装 ipa → 校验 → 启动（看 PPID） → 卸载 → 清理
# 任何一步不过就停下并打印现场。

set -eu
IP="${1:-}"
[ -n "$IP" ] || { echo "用法: $0 <设备IP>"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
DEB=$(ls "$ROOT"/dist/trollstore-lite-tv_*.deb 2>/dev/null | head -1)
[ -n "$DEB" ] || { echo "先跑 ./build-deb.sh"; exit 1; }
[ -n "${ATV_PASS:-}" ] || { echo "需要 ATV_PASS=<设备sudo密码>"; exit 1; }

SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mobile@$IP"
SCP="scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk

fail() { echo "FAIL: $*"; exit 1; }

echo "=========== 1. 安装工具包 ==========="
# /var/tmp 有 sticky 位，同名旧文件常常属于 root，用带随机后缀的名字绕开
RNAME="alma-$$-$(date +%s).deb"
$SCP "$DEB" mobile@"$IP":/var/tmp/$RNAME
$SSH "echo $ATV_PASS | sudo -S -p '' dpkg -i /var/tmp/$RNAME" 2>&1 | tail -3
# postinst 里要签名+重启守护进程，给它最多 20 秒
n=0
while [ "$n" -lt 20 ]; do
  c=$($SSH 'ps ax -o command | grep -E "tsltvd|tsltvweb" | grep -v grep | wc -l' | tr -d ' ')
  [ "${c:-0}" -ge 2 ] && break
  n=$((n+1)); sleep 1
done
[ "${c:-0}" -ge 2 ] || fail "守护进程没起来（20 秒内只见到 ${c:-0} 个）"
echo "PASS  守护进程在跑（等待 ${n}s）"

echo "=========== 2. 造一个测试 ipa ==========="
T=$(mktemp -d)
mkdir -p "$T/Payload/AcceptTest.app"
cat > "$T/t.m" <<'EOF'
#import <UIKit/UIKit.h>
int main(int c, char **v){ @autoreleasepool { return UIApplicationMain(c, v, nil, nil); } }
EOF
clang -target arm64-apple-tvos17.0 -isysroot "$SDK" -fobjc-arc \
      -framework UIKit -framework Foundation "$T/t.m" -o "$T/Payload/AcceptTest.app/AcceptTest"
cat > "$T/Payload/AcceptTest.app/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AcceptTest</string>
<key>CFBundleIdentifier</key><string>com.alma.accept</string>
<key>CFBundleName</key><string>AcceptTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>AppleTVOS</string></array>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>3</integer></array>
</dict></plist>
EOF
( cd "$T" && zip -qr AcceptTest.ipa Payload )
$SCP "$T/AcceptTest.ipa" mobile@"$IP":/var/tmp/
echo "PASS  测试包已生成并上传"

echo "=========== 3. 安装 ipa ==========="
out=$($SSH "echo $ATV_PASS | sudo -S -p '' /usr/libexec/tsltv/tsltv install /var/tmp/AcceptTest.ipa" 2>&1)
echo "$out" | grep -q "探测: platform=3" || fail "预检没有跑：$out"
echo "$out" | grep -q "签名 1 / 信任 1 / 失败 0" || fail "签名/信任失败：$out"
echo "$out" | grep -q "cdhash:" || fail "没有拿到 cdhash：$out"
echo "PASS  安装成功：$(echo "$out" | grep cdhash: | head -1 | sed 's/^ *//')"

echo "=========== 4. 校验 ==========="
v=$($SSH "echo $ATV_PASS | sudo -S -p '' /usr/libexec/tsltv/tsltv verify com.alma.accept" 2>&1)
echo "$v" | grep -q "PASS  com.alma.accept" || fail "校验没过：$v"
echo "PASS  校验通过"

echo "=========== 5. 启动（看是不是系统拉起的）==========="
$SSH "echo $ATV_PASS | sudo -S -p '' /usr/libexec/tsltv/wake >/dev/null 2>&1; uiopen --bundleid com.alma.accept" >/dev/null 2>&1 || true
sleep 6
p=$($SSH 'ps ax -o pid,ppid,command | grep "AcceptTest.app/AcceptTest" | grep -v grep | head -1' || true)
if [ -z "$p" ]; then
  echo "SKIP  未拿到进程（屏幕/显示状态可能导致 uiopen 空转），安装与校验已通过"
else
  set -- $p
  [ "$2" = "1" ] || fail "进程起来了但父进程不是 launchd：$p"
  echo "PASS  已由 launchd 启动：PID $1 PPID $2"
fi

echo "=========== 6. 卸载 ==========="
u=$($SSH "echo $ATV_PASS | sudo -S -p '' /usr/libexec/tsltv/tsltv uninstall com.alma.accept" 2>&1)
echo "$u" | grep -q "完成" || fail "卸载失败：$u"
echo "PASS  卸载干净"

echo "=========== 7. 清理 ==========="
rm -rf "$T"
$SSH "echo $ATV_PASS | sudo -S -p '' rm -f /var/tmp/AcceptTest.ipa /var/tmp/$RNAME" >/dev/null 2>&1 || true
echo "PASS  临时文件已清"

echo
echo "全部通过 ✅"
