#!/bin/sh
# AlmaTrust —— tvOS 版 TrollStore 式安装器
#
# 用法:
#   install.sh /path/to/App.app
#   install.sh /path/to/App.ipa
#
# 流程: 解包 -> ldid 双哈希自签(带 get-z...
#       -> 写入越狱信任缓存 -> 装到 /Applications -> 注册 -> 记入清单
# 前提: 已越狱(Relaxin/roothide)，以 root 运行。

set -u

BASE=/usr/libexec/almatrust
WORK=/var/tmp/almatrust/work
STAGE=/var/tmp/almatrust/staging
ENT=/var/tmp/almatrust/ent.plist
. "$BASE/trustlib.sh"

SRC="${1:-}"
[ -n "$SRC" ] || { echo "用法: install.sh <App.app | xxx.ipa>"; exit 1; }
[ -e "$SRC" ] || { echo "找不到: $SRC"; exit 1; }

APP=""
case "$SRC" in
  *.ipa)
    rm -rf "$WORK"; mkdir -p "$WORK"
    if command -v unzip >/dev/null 2>&1; then
      unzip -q -o "$SRC" -d "$WORK" || { echo "解压失败"; exit 1; }
    else
      tar -xf "$SRC" -C "$WORK" || { echo "解压失败（tar 不支持 zip？）"; exit 1; }
    fi
    APP=$(ls -d "$WORK"/Payload/*.app 2>/dev/null | head -1)
    ;;
  *.app)
    APP="$SRC"
    ;;
  *)
    echo "不支持的类型: $SRC（只接受 .app / .ipa）"
    exit 1
    ;;
esac

[ -n "$APP" ] && [ -d "$APP" ] || { echo "包里没有 .app"; exit 1; }

NAME=$(basename "$APP" .app)
BID=$(plutil "$APP/Info.plist" 2>/dev/null | grep CFBundleIdentifier | sed 's/.*= //; s/;//' | tr -d '"')
EXE=$(plutil "$APP/Info.plist" 2>/dev/null | grep CFBundleExecutable | sed 's/.*= //; s/;//' | tr -d '"')
[ -n "$EXE" ] || EXE="$NAME"
[ -n "$BID" ] || BID="alma.$NAME"

echo "==> $NAME ($BID)"

mkdir -p "$STAGE" /var/tmp/almatrust
rm -rf "$STAGE/$NAME.app"
cp -a "$APP" "$STAGE/$NAME.app" || { echo "复制失败"; exit 1; }
TARGET="$STAGE/$NAME.app"

cat >"$ENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>application-identifier</key><string>$BID</string>
	<key>get-task-allow</key><true/>
	<key>platform-application</key><true/>
	<key>com.apple.private.security.no-sandbox</key><true/>
	<key>com.apple.private.security.no-container</key><true/>
	<key>com.apple.private.security.container-required</key><false/>
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

# 待签名的二进制：主可执行文件 + Frameworks/PlugIns 里的普通文件（跳过符号链接）
LIST="/var/tmp/almatrust/list.$$"
: >"$LIST"
[ -f "$TARGET/$EXE" ] && echo "$TARGET/$EXE" >>"$LIST"
find "$TARGET/Frameworks" "$TARGET/PlugIns" -type f 2>/dev/null >>"$LIST"

signed=0
trusted=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  [ -L "$f" ] && continue
  case "$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" in
    cffaedfe|cafebabe|cefaedfe|feedfacf) ;;
    *) continue ;;
  esac
  if ldid -S"$ENT" -Cadhoc -Hsha1 -Hsha256 "$f" >/dev/null 2>&1; then
    signed=$((signed + 1))
    # 2026-11-23 实测：越狱的 exec 钩子会在 app 启动时自动写入 cdhash，
    # 这里预填充只是保险（可用 ALMA_NO_TRUST=1 跳过）。
    if [ "${ALMA_NO_TRUST:-0}" != "1" ] && $JBCTL trustcache add "$f" >/dev/null 2>&1; then
      trusted=$((trusted + 1))
    fi
  fi
done <"$LIST"
rm -f "$LIST"

echo "==> 签名 $signed / 信任 $trusted"

DEST="/Applications/$NAME.app"
if [ -d "$DEST" ]; then
  uicache -u "$DEST" >/dev/null 2>&1
  rm -rf "$DEST"
fi
cp -a "$TARGET" "$DEST" || { echo "安装失败"; exit 1; }
chown -R mobile:mobile "$DEST"

# 记录到清单，重启(重新越狱)后由 com.alma.retrust 重放
manifest_add "$DEST/$EXE"
find "$DEST/Frameworks" "$DEST/PlugIns" -type f 2>/dev/null >/tmp/.atlist.$$
while IFS= read -r f; do
  [ -f "$f" ] || continue
  [ -L "$f" ] && continue
  case "$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" in
    cffaedfe|cafebabe|cefaedfe|feedfacf) manifest_add "$f" ;;
  esac
done </tmp/.atlist.$$
rm -f /tmp/.atlist.$$

uicache -p "$DEST" >/dev/null 2>&1
say "installed $DEST ($BID) signed=$signed trusted=$trusted"

echo "==> 完成: $DEST"
echo "    启动: uiopen --bundleid $BID"
