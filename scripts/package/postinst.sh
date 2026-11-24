#!/bin/sh
set -eu

JB=
for candidate in /var/containers/Bundle/Application/.jbroot-*; do
  [ -d "$candidate" ] || continue
  JB=$candidate
  break
done
[ -n "$JB" ] || { echo "找不到 Relaxin jbroot" >&2; exit 1; }
LDID=$(command -v ldid 2>/dev/null || true)
[ -n "$LDID" ] || LDID=$JB/usr/bin/ldid
JBCTL=$JB/usr/bin/jbctl
[ -x "$LDID" ] || { echo "找不到可执行的 ldid: $LDID" >&2; exit 1; }
[ -x "$JBCTL" ] || { echo "找不到可执行的 jbctl: $JBCTL" >&2; exit 1; }

BIN=/usr/libexec/tsltv
APP=/Applications/TrollStoreLiteTV.app
ENT=/var/tmp/trollstore-lite-tv.ent
TRUST_TMP=/var/tmp/trollstore-lite-tv.trustbin
trap 'rm -f "$ENT" "$ENT.one" "$TRUST_TMP"' 0

chmod 755 "$BIN/tsltv" "$BIN/tsltvd" "$BIN/tsltvweb" "$BIN/retrust.sh" \
  "$BIN/tsh" "$BIN/wake" "$BIN/modinject" "$BIN/machoscan"

cat > "$ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>get-task-allow</key><true/>
<key>platform-application</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
<key>com.apple.private.security.no-container</key><true/>
<key>com.apple.private.security.container-required</key><false/>
</dict></plist>
EOF

sign_and_trust() {
  file=$1
  appid=$2
  [ -f "$file" ] || { echo "签名组件不存在: $file" >&2; return 1; }
  sed "s|<dict>|<dict><key>application-identifier</key><string>$appid</string>|" \
    "$ENT" > "$ENT.one" || { echo "生成 entitlement 失败: $file" >&2; return 1; }
  "$LDID" -S"$ENT.one" -Cadhoc -Hsha1 -Hsha256 "$file" || {
    echo "签名失败: $file" >&2
    return 1
  }
  if ! "$JBCTL" trustcache add "$file" >/dev/null 2>&1; then
    cp "$file" "$TRUST_TMP" && "$JBCTL" trustcache add "$TRUST_TMP" >/dev/null 2>&1 || {
      rm -f "$TRUST_TMP"
      echo "信任注入失败: $file" >&2
      return 1
    }
    rm -f "$TRUST_TMP"
  fi
}

# 只签 Mach-O 二进制；tsh 是 POSIX sh 脚本，不能交给 ldid
sign_and_trust "$BIN/tsltvweb" com.trollstorelite.tv.web
sign_and_trust "$BIN/wake" com.trollstorelite.tv.wake
sign_and_trust "$BIN/modinject" com.trollstorelite.tv.modinject
sign_and_trust "$BIN/machoscan" com.trollstorelite.tv.machoscan
sign_and_trust "$APP/TrollStoreLiteTV" com.trollstorelite.tv

mkdir -p /var/tmp/tsltv-inbox
chmod 777 /var/tmp/tsltv-inbox
for name in tsltv trollstore-lite-tv trollstore-lite-tv-cli tsl tsltv-cli; do
  ln -sf "$BIN/tsltv" "/usr/bin/$name"
done
ln -sf "$BIN/tsh" /usr/bin/tsh

uicache -p "$APP" >/dev/null 2>&1 || true

ALL_JOBS="com.trollstorelite.tv.daemon com.trollstorelite.tv.web com.trollstorelite.tv.retrust"
RUN_JOBS="com.trollstorelite.tv.daemon com.trollstorelite.tv.web"
for job in $ALL_JOBS; do
  launchctl bootout "system/$job" >/dev/null 2>&1 || true
done
sleep 1

started=0
for _ in 1 2 3 4 5; do
  for job in $ALL_JOBS; do
    if ! launchctl print "system/$job" >/dev/null 2>&1; then
      launchctl bootstrap system "/Library/LaunchDaemons/$job.plist" >/dev/null 2>&1 || true
    fi
  done
  all_running=1
  for job in $RUN_JOBS; do
    if ! launchctl print "system/$job" 2>/dev/null | grep -q 'state = running'; then
      all_running=0
    fi
  done
  if [ "$all_running" -eq 1 ]; then
    started=1
    break
  fi
  sleep 1
done
[ "$started" -eq 1 ] || echo "警告: 部分 LaunchDaemon 尚未进入 running，请检查 /var/log/tsltv*.log" >&2

VER=$(cat /usr/libexec/tsltv/VERSION 2>/dev/null || echo unknown)
echo "TrollStore Lite TV $VER installed:"
echo "  TV app   TrollStore Lite TV (TrollStoreLiteTV.app)"
echo "  Web      http://<device-ip>:8787"
echo "  CLI      tsltv | trollstore-lite-tv | tsl"
