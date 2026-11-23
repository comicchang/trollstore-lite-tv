#!/bin/sh
# AlmaTrust v2 —— 参照 TrollStore Lite 源码改进的安装器
#
# 与 v1 的差异（都来自 opa334/TrollStore 的 RootHelper/main.m）：
#   1. 安装位置改为 /private/var/containers/Bundle/Application/<UUID>/App.app
#      （v1 装 jbroot 的 /Applications；v2 走 TrollStore 同款路径）
#   2. entitlements 里 `com.apple.private.security.container-required` 用 **bundle id 字符串**
#      （v1 用 false；Lite 源码注释说容器要靠这个才能工作）
#   3. 增加 `jb.pmap_cs.custom_trust = PMAP_CS_APP_STORE`
#      （Lite 专有：adhoc 签名会让二进制落到 IN_LOADED_TRUST_CACHE 级别，需要覆盖）
#   4. 落 `.TrollStorePersistenceHelper` 标记文件（兼容原版 TrollStore 的助手判定）
#   5. 注册时优先用 `uicache -s`（登记为 System）
#
# 用法:
#   install_v2.sh /path/to/App.app
#   install_v2.sh /path/to/App.ipa
#
# 前提：已越狱，root 运行。

set -u

BASE=/usr/libexec/almatrust
WORK=/var/tmp/almatrust/work
ENT=/var/tmp/almatrust/ent2.plist
JBCTL=/basebin/jbctl
MANIFEST="$BASE/manifest.txt"
LOGF=/var/log/almatrust.log
CONTAINERS=/private/var/containers/Bundle/Application

say() { echo "$(date '+%H:%M:%S') $*" >>"$LOGF" 2>/dev/null; }

is_macho() {
  [ -f "$1" ] || return 1
  [ -L "$1" ] && return 1
  case "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" in
    cffaedfe|cafebabe|cefaedfe|feedfacf) return 0 ;;
  esac
  return 1
}

SRC="${1:-}"
[ -n "$SRC" ] || { echo "用法: install_v2.sh <App.app | xxx.ipa>"; exit 1; }
[ -e "$SRC" ] || { echo "找不到: $SRC"; exit 1; }

APP=""
case "$SRC" in
  *.ipa)
    rm -rf "$WORK"; mkdir -p "$WORK"
    if command -v unzip >/dev/null 2>&1; then
      unzip -q -o "$SRC" -d "$WORK" || { echo "解压失败"; exit 1; }
    else
      tar -xf "$SRC" -C "$WORK" || { echo "解压失败"; exit 1; }
    fi
    APP=$(ls -d "$WORK"/Payload/*.app 2>/dev/null | head -1)
    ;;
  *.app) APP="$SRC" ;;
  *) echo "不支持: $SRC"; exit 1 ;;
esac
[ -n "$APP" ] && [ -d "$APP" ] || { echo "包里没有 .app"; exit 1; }

NAME=$(basename "$APP" .app)
BID=$(plutil "$APP/Info.plist" 2>/dev/null | grep CFBundleIdentifier | sed 's/.*= //; s/;//' | tr -d '"')
EXE=$(plutil "$APP/Info.plist" 2>/dev/null | grep CFBundleExecutable | sed 's/.*= //; s/;//' | tr -d '"')
[ -n "$EXE" ] || EXE="$NAME"
[ -n "$BID" ] || BID="alma.$NAME"

echo "==> $NAME ($BID)"

UUID=$(uuidgen 2>/dev/null || echo "ALMA$(date +%s)")
DEST_DIR="$CONTAINERS/$UUID"
DEST="$DEST_DIR/$NAME.app"

mkdir -p "$DEST_DIR" /var/tmp/almatrust
cp -a "$APP" "$DEST" || { echo "复制失败"; exit 1; }

# —— ent2：TrollStore Lite 同款关键项 ——
cat >"$ENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>application-identifier</key><string>$BID</string>
	<key>com.apple.developer.team-identifier</key><string>TROLLTROLL</string>
	<key>get-task-allow</key><true/>
	<key>platform-application</key><true/>
	<key>com.apple.private.security.no-sandbox</key><true/>
	<key>com.apple.private.security.no-container</key><true/>
	<key>com.apple.private.security.container-required</key><string>$BID</string>
	<key>jb.pmap_cs.custom_trust</key><string>PMAP_CS_APP_STORE</string>
	<key>com.apple.security.network.client</key><true/>
	<key>com.apple.security.network.server</key><true/>
	<key>com.apple.security.iokit-user-client-class</key>
	<array>
		<string>AGXCommandQueue</string><string>AGXDevice</string>
		<string>AGXDeviceUserClient</string><string>AGXSharedUserClient</string>
		<string>IOAccelerator</string><string>IOAccelDevice</string>
		<string>IOAccelContext</string><string>IOAccelDevice2</string>
		<string>IOAccelContext2</string><string>IOAccelSharedUserClient</string>
		<string>IOSurfaceRootUserClient</string>
	</array>
</dict></plist>
EOF

# 主可执行 + Frameworks/PlugIns 里的 Mach-O
LIST=/var/tmp/almatrust/list.$$
: >"$LIST"
[ -f "$DEST/$EXE" ] && echo "$DEST/$EXE" >>"$LIST"
find "$DEST/Frameworks" "$DEST/PlugIns" -type f 2>/dev/null >>"$LIST"

signed=0; trusted=0
while IFS= read -r f; do
  is_macho "$f" || continue
  if ldid -S"$ENT" -Cadhoc -Hsha1 -Hsha256 "$f" >/dev/null 2>&1; then
    signed=$((signed + 1))
    # v2 仍然写入信任缓存：CoreTrust 路线未验证前，这是唯一可靠的放行手段
    if $JBCTL trustcache add "$f" >/dev/null 2>&1; then
      trusted=$((trusted + 1))
    fi
  fi
done <"$LIST"
rm -f "$LIST"

chown -R mobile:mobile "$DEST_DIR"
chmod 755 "$DEST/$EXE" 2>/dev/null

# 原版 TrollStore 的助手标记（无害，便于将来兼容）
touch "$DEST/.TrollStorePersistenceHelper"

# 注册（-s = 登记为 System）
uicache -s -p "$DEST" >/dev/null 2>&1 || uicache -p "$DEST" >/dev/null 2>&1

# 记入重放清单
echo "$DEST/$EXE" >>"$MANIFEST"
find "$DEST/Frameworks" "$DEST/PlugIns" -type f 2>/dev/null | while IFS= read -r f; do
  is_macho "$f" && echo "$f" >>"$MANIFEST"
done
sort -u "$MANIFEST" -o "$MANIFEST" 2>/dev/null

say "installed(v2) $DEST ($BID) signed=$signed trusted=$trusted"

echo "==> 签名 $signed / 信任 $trusted"
echo "==> 完成: $DEST"
echo "    启动: uiopen --bundleid $BID"
