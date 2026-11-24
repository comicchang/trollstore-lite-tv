#!/bin/sh
# 在**本机**打包（不需要设备）——用于 CI 与没有越狱设备时出包
#
#   ./scripts/build-deb-local.sh [VER]
#
# 依赖：dpkg-deb（macOS: brew install dpkg；Linux: apt install dpkg）
# 产物：dist/trollstore-lite-tv_<VER>_appletvos-arm64e.deb
#
# 与 scripts/build-deb.sh 的区别：后者把打包放到设备上执行（历史原因：早期 macOS 的 ar
# 打出来的归档 dpkg 不认）。现在用 dpkg-deb -b 即可，两条路都保留。

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
VER="${1:-${VER:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)}}"
ARCH=appletvos-arm64e
DEB=trollstore-lite-tv_${VER}_${ARCH}.deb
STAGE=$(mktemp -d)/pkg

command -v dpkg-deb >/dev/null 2>&1 || {
  echo "需要 dpkg-deb：macOS 用 brew install dpkg，Linux 用 apt install dpkg"; exit 1; }

echo "==> 编译组件"
sh "$ROOT/src/web/build.sh"   >/dev/null
sh "$ROOT/src/gui/build.sh"   >/dev/null
sh "$ROOT/src/tools/build.sh" >/dev/null

echo "==> 暂存"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/libexec/tsltv" \
         "$STAGE/Library/LaunchDaemons" "$STAGE/Applications"
cp "$ROOT/src/cli/tsltv"              "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/daemon/tsltvd"          "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/daemon/retrust.sh"      "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/fork/tsh"               "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/web/tsltvweb"           "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/tools/wake"             "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/tools/modinject" "$STAGE/usr/libexec/tsltv/"
cp "$ROOT/src/tools/machoscan" "$STAGE/usr/libexec/tsltv/"
printf '%s\n' "$VER" >                "$STAGE/usr/libexec/tsltv/VERSION"
cp "$ROOT/src/daemon/"com.trollstorelite.tv.*.plist "$STAGE/Library/LaunchDaemons/"
cp -a "$ROOT/src/gui/TrollStoreLiteTV.app"       "$STAGE/Applications/"
plutil -replace CFBundleShortVersionString -string "$VER" \
       "$STAGE/Applications/TrollStoreLiteTV.app/Info.plist" 2>/dev/null || true

cat > "$STAGE/DEBIAN/control" <<EOF
Package: trollstore-lite-tv
Name: TrollStore Lite TV
Version: $VER
Architecture: $ARCH
Maintainer: Comic Chang
Section: Applications
Priority: optional
Description: TrollStore-Lite-style installer for jailbroken tvOS (unofficial)
 Install and run unsigned tvOS apps on a jailbroken Apple TV. Ad-hoc dual-hash
 signing plus Relaxin/roothide kernel trust cache - no Apple certificate and no
 CoreTrust exploit. Ships a TV UI, a web store and a CLI (tsltv).
EOF

cp "$ROOT/scripts/package/postinst.sh" "$STAGE/DEBIAN/postinst"
cp "$ROOT/scripts/package/prerm.sh" "$STAGE/DEBIAN/prerm"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"
chmod 644 "$STAGE/DEBIAN/control"
chmod 755 "$STAGE/usr/libexec/tsltv/tsh" "$STAGE/usr/libexec/tsltv/wake"
find "$STAGE" -name "._*" -delete 2>/dev/null || true

echo "==> 打包"
mkdir -p "$ROOT/dist"
# --root-owner-group：让包内文件属主为 root:root（在 macOS 上跑时必须）
dpkg-deb --root-owner-group -b "$STAGE" "$ROOT/dist/$DEB" >/dev/null
rm -rf "$(dirname "$STAGE")"

ls -lh "$ROOT/dist/$DEB"
echo "安装： scp 到设备后  sudo dpkg -i $DEB"
