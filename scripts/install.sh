#!/bin/sh
# 从 Mac 一条命令把 TrollStoreLiteTV Lite 装到 Apple TV 上
#
#   ATV_PASS=<设备sudo密码> ./install.sh [设备IP]
#
# 会做：上传 deb → dpkg -i → 打印三个入口 → 自检

set -eu
IP="${1:-}"
[ -n "$IP" ] || { echo "用法: $0 <设备IP>"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
DEB=$(ls "$ROOT"/dist/trollstore-lite-tv_*.deb 2>/dev/null | head -1)
[ -n "$DEB" ] || { echo "找不到 .deb，先跑 ./scripts/build-deb.sh"; exit 1; }
[ -n "${ATV_PASS:-}" ] || { echo "需要 ATV_PASS=<设备sudo密码>"; exit 1; }

SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mobile@$IP"
SCP="scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "==> 上传 $(basename "$DEB")"
$SCP "$DEB" mobile@"$IP":/var/tmp/

echo "==> 安装"
$SSH "R(){ echo \"\$ATV_PASS\" | sudo -S -p '' \"\$@\"; }; R dpkg -i /var/tmp/$(basename "$DEB")" 2>&1 | tail -6

sleep 3
echo "==> 自检"
$SSH "R(){ echo \"\$ATV_PASS\" | sudo -S -p '' \"\$@\"; }; \
      echo '--- 服务 ---'; \
      ps ax -o pid,etime,command | grep -E 'tsltvd|tsltvweb' | grep -v grep | awk '{print \$1, \$2, \$3}'; \
      echo '--- 应用 ---'; uicache -l | grep -i tsltv; \
      echo '--- 校验 ---'; R /usr/libexec/tsltv/tsltv verify | tail -3"

echo
echo "打开 http://$IP:8787 ，或在电视主屏点 TrollStoreLiteTV。"
