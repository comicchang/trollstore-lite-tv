#!/bin/sh
# 构建 TrollStoreLiteTV Lite 的 .deb
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
VER="${VER:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)}"
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
cp "$ROOT/src/tools/modinject" "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/daemon/"com.trollstorelite.tv.*.plist  "$STAGE/Library/LaunchDaemons/"
cp -a "$ROOT/src/gui/TrollStoreLiteTV.app"     "$STAGE/Applications/"

# 让界面显示的版本与包版本一致
plutil -replace CFBundleShortVersionString -string "$VER" \
       "$STAGE/Applications/TrollStoreLiteTV.app/Info.plist" 2>/dev/null || true

cat > "$STAGE/DEBIAN/control" <<EOF
Package: trollstore-lite-tv
Name: TrollStore Lite TV
Version: $VER
Architecture: $ARCH
Maintainer: TrollStoreLiteTV
Section: Applications
Priority: optional
Description: TrollStore-Lite for jailbroken tvOS - install and run ad-hoc signed apps
 Installable as tsltv / trollstore-lite / tsl. Signs any unencrypted .ipa with
 ad-hoc dual-hash signing, injects the cdhash into the Relaxin/roothide kernel trust
 cache, registers with LaunchServices, and exposes a TV UI plus a web store. Rejects
 encrypted App Store binaries, ships a TrollStore-RootHelper-compatible front (tsh)
 and a HID wake helper.
EOF

cp "$ROOT/scripts/package/postinst.sh" "$STAGE/DEBIAN/postinst"
cp "$ROOT/scripts/package/prerm.sh" "$STAGE/DEBIAN/prerm"

chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"
chmod 644 "$STAGE/DEBIAN/control"
chmod 755 "$STAGE/usr/libexec/tsltv/tsh" "$STAGE/usr/libexec/tsltv/wake"
find "$STAGE" -name "._*" -delete 2>/dev/null || true

echo "==> 推送到设备并打包"
export COPYFILE_DISABLE=1
tar -czf /tmp/tsltv-src.tar.gz -C "$STAGE" .
$SCP /tmp/tsltv-src.tar.gz mobile@"$IP":/var/tmp/
$SSH "echo $ATV_PASS | sudo -S -p '' sh -c '
  rm -rf /var/tmp/tsltv-pkg && mkdir -p /var/tmp/tsltv-pkg
  tar -xzf /var/tmp/tsltv-src.tar.gz -C /var/tmp/tsltv-pkg
  chown -R root:wheel /var/tmp/tsltv-pkg
  dpkg-deb -b /var/tmp/tsltv-pkg /var/tmp/$DEB >/dev/null 2>&1
  rm -rf /var/tmp/tsltv-pkg /var/tmp/tsltv-src.tar.gz
'" || true

echo "==> 取回产物"
$SCP mobile@"$IP":/var/tmp/"$DEB" "$ROOT/dist/$DEB"
$SSH "echo $ATV_PASS | sudo -S -p '' rm -f /var/tmp/$DEB" >/dev/null 2>&1 || true
rm -rf "$(dirname "$STAGE")" /tmp/tsltv-src.tar.gz

ls -lh "$ROOT/dist/$DEB"
echo "安装： scp 到设备后  sudo dpkg -i $DEB"
