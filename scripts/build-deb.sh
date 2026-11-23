#!/bin/sh
# 构建 TSLTV Lite 的 .deb
#
#   ATV_PASS=<设备sudo密码> ./scripts/build-deb.sh [设备IP]
#
# 为什么在设备上打包：macOS 的 ar 打出来的归档 dpkg 不认（只有 __.SYMDEF）；
# 设备自带 dpkg-deb，直接用它打最可靠。
#
# 产物：dist/trollstore-lite-tv_<VER>_appletvos-arm64e.deb

set -eu
IP="${1:-}"
[ -n "$IP" ] || { echo "用法: $0 <设备IP>"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
VER="${VER:-1.0.12}"
ARCH=appletvos-arm64e
DEB=trollstore-lite-tv_${VER}_${ARCH}.deb
STAGE=$(mktemp -d)/pkg

SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mobile@$IP"
SCP="scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "==> 编译组件"
sh "$ROOT/src/web/build.sh"   >/dev/null
sh "$ROOT/src/gui/build.sh"   >/dev/null
sh "$ROOT/src/tools/build.sh" >/dev/null

echo "==> 准备暂存目录"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/libexec/tsltv" \
         "$STAGE/Library/LaunchDaemons" "$STAGE/Applications"

cp "$ROOT/src/cli/tsltv"            "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/daemon/tsltvd"        "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/daemon/retrust.sh"        "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/fork/tsh"                 "$STAGE/usr/libexec/tsltv/"
echo "$VER" > "$STAGE/usr/libexec/tsltv/VERSION"
cp "$ROOT/src/web/tsltvweb"         "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/tools/wake"               "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/daemon/"com.alma.*.plist  "$STAGE/Library/LaunchDaemons/"
cp -a "$ROOT/src/gui/TSLTV.app"     "$STAGE/Applications/"

# 让界面显示的版本与包版本一致
plutil -replace CFBundleShortVersionString -string "$VER" \
       "$STAGE/Applications/TSLTV.app/Info.plist" 2>/dev/null || true

cat > "$STAGE/DEBIAN/control" <<EOF
Package: trollstore-lite-tv
Name: TSLTV Lite
Version: $VER
Architecture: $ARCH
Maintainer: Alma
Section: Applications
Priority: optional
Description: TrollStore-Lite for jailbroken tvOS - install and run ad-hoc signed apps
 Installable as tsltv / trollstore-lite / tsl. Signs any unencrypted .ipa with
 ad-hoc dual-hash signing, injects the cdhash into the Relaxin/roothide kernel trust
 cache, registers with LaunchServices, and exposes a TV UI plus a web store. Rejects
 encrypted App Store binaries, ships a TrollStore-RootHelper-compatible front (tsh)
 and a HID wake helper.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
JB=$(ls -d /var/containers/Bundle/Application/.jbroot-* 2>/dev/null | head -1)
LDID=$(command -v ldid || echo "$JB/usr/bin/ldid")
JBCTL="$JB/usr/bin/jbctl"
ENT=/var/tmp/trollstore-lite-tv.ent

chmod 755 /usr/libexec/tsltv/tsltv /usr/libexec/tsltv/tsltvd \
          /usr/libexec/tsltv/tsltvweb /usr/libexec/tsltv/retrust.sh \
          /usr/libexec/tsltv/tsh /usr/libexec/tsltv/wake 2>/dev/null || true

# dpkg 覆盖文件会丢签名，这里补签并注入信任缓存
cat > "$ENT" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>get-task-allow</key><true/>
<key>platform-application</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
<key>com.apple.private.security.no-container</key><true/>
<key>com.apple.private.security.container-required</key><false/>
</dict></plist>
EOF2

sign_and_trust() {
  f="$1"; appid="$2"
  [ -f "$f" ] || return 0
  sed "s|<dict>|<dict><key>application-identifier</key><string>$appid</string>|" "$ENT" > "$ENT.one"
  "$LDID" -S"$ENT.one" -Cadhoc -Hsha1 -Hsha256 "$f" 2>/dev/null || return 0
  "$JBCTL" trustcache add "$f" >/dev/null 2>&1 || true
}
sign_and_trust /usr/libexec/tsltv/tsltvweb com.alma.tsltvweb
sign_and_trust /usr/libexec/tsltv/wake        com.alma.wake
sign_and_trust /Applications/TSLTV.app/TSLTV com.alma.tsltv
rm -f "$ENT" "$ENT.one"

mkdir -p /var/tmp/tsltv-inbox; chmod 777 /var/tmp/tsltv-inbox 2>/dev/null || true
for n in tsltv trollstore-lite-tv trollstore-lite-tv-cli tsl tsltv-cli; do
  ln -sf /usr/libexec/tsltv/tsltv /usr/bin/$n 2>/dev/null || true
done

uicache -p /Applications/TSLTV.app >/dev/null 2>&1 || true

JOBS="com.alma.tsltv.daemon com.alma.tsltv.web com.alma.tsltv.retrust"

for job in $JOBS; do
  launchctl bootout system/$job >/dev/null 2>&1 || true
done
sleep 1

# launchd 有时会静默拒绝 bootstrap，重试几次并确认 state=running
for i in 1 2 3 4 5; do
  ok=1
  for job in $JOBS; do
    if ! launchctl print system/$job >/dev/null 2>&1; then
      launchctl bootstrap system /Library/LaunchDaemons/$job.plist >/dev/null 2>&1 || true
    fi
    launchctl print system/$job 2>/dev/null | grep -q "state = running" || ok=0
  done
  [ "$ok" = "1" ] && break
  sleep 1
done

echo "TrollStore Lite TV $VER installed:"
echo "  TV app   TrollStore Lite TV (TSLTV.app)"
echo "  Web      http://<device-ip>:8787"
echo "  CLI      tsltv | trollstore-lite-tv | tsl"
exit 0
POSTINST

cat > "$STAGE/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
for job in com.alma.tsltvd com.alma.tsltvweb com.alma.retrust; do
  launchctl bootout system/$job >/dev/null 2>&1 || true
done
uicache -u /Applications/TSLTV.app >/dev/null 2>&1 || true
rm -f /usr/bin/tsltv /usr/bin/trollstore-lite /usr/bin/tsl 2>/dev/null || true
exit 0
PRERM

chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"
chmod 644 "$STAGE/DEBIAN/control"
chmod 755 "$STAGE/usr/libexec/tsltv/tsh" "$STAGE/usr/libexec/tsltv/wake"
find "$STAGE" -name "._*" -delete 2>/dev/null || true

echo "==> 推送到设备并打包"
export COPYFILE_DISABLE=1
tar -czf /tmp/alma-pkg-src.tar.gz -C "$STAGE" .
$SCP /tmp/alma-pkg-src.tar.gz mobile@"$IP":/var/tmp/
$SSH "echo $ATV_PASS | sudo -S -p '' sh -c '
  rm -rf /var/tmp/alma-pkg && mkdir -p /var/tmp/alma-pkg
  tar -xzf /var/tmp/alma-pkg-src.tar.gz -C /var/tmp/alma-pkg
  chown -R root:wheel /var/tmp/alma-pkg
  dpkg-deb -b /var/tmp/alma-pkg /var/tmp/$DEB >/dev/null 2>&1
  rm -rf /var/tmp/alma-pkg /var/tmp/alma-pkg-src.tar.gz
'" || true

echo "==> 取回产物"
$SCP mobile@"$IP":/var/tmp/"$DEB" "$ROOT/dist/$DEB"
$SSH "echo $ATV_PASS | sudo -S -p '' rm -f /var/tmp/$DEB" >/dev/null 2>&1 || true
rm -rf "$(dirname "$STAGE")" /tmp/alma-pkg-src.tar.gz

ls -lh "$ROOT/dist/$DEB"
echo "安装： scp 到设备后  sudo dpkg -i $DEB"
