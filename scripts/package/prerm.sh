#!/bin/sh
set -eu

# 升级（含 selfupdate）时交由新包 postinst 重签并平滑重启，避免提前停服或半配置断链
case "${1:-remove}" in
  upgrade|deconfigure|failed-upgrade) exit 0 ;;
esac

for job in com.trollstorelite.tv.daemon com.trollstorelite.tv.web com.trollstorelite.tv.retrust; do
  launchctl bootout "system/$job" >/dev/null 2>&1 || true
done
uicache -u /Applications/TrollStoreLiteTV.app >/dev/null 2>&1 || true
rm -f /usr/bin/tsltv /usr/bin/trollstore-lite-tv /usr/bin/trollstore-lite-tv-cli \
  /usr/bin/tsl /usr/bin/tsltv-cli /usr/bin/tsh
rm -rf /var/run/tsltv
