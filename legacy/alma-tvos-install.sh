#!/bin/sh
# alma-tvos-install —— 从 Mac 一键装 tvOS 应用到越狱的 Apple TV
#
# 用法:
#   ./alma-tvos-install.sh /path/to/App.ipa
#   ./alma-tvos-install.sh /path/to/App.app
#
# 做的事情：
#   1. 把包推到设备的 /var/tmp/
#   2. 调设备上的 AlmaTrust 安装器（自签名 + 写信任 + 装到 /Applications + 注册）
#   3. 打印启动命令
#
# 前提：Mac 已能免密 ssh mobile@<ATV_IP>；设备已越狱。

set -eu

ATV_IP="${ATV_IP:-192.168.1.23}"
ATV_USER="${ATV_USER:-mobile}"
INSTALLER="/usr/libexec/almatrust/install.sh"

# 设备上 sudo 用的密码：优先用环境变量 ATV_PASS，否则交互式询问（不回显、不落盘）
if [ -z "${ATV_PASS:-}" ]; then
  printf 'Apple TV 上 %s 的 sudo 密码: ' "${ATV_USER}"
  stty -echo 2>/dev/null || true
  read -r ATV_PASS
  stty echo 2>/dev/null || true
  echo
fi
[ -n "${ATV_PASS}" ] || { echo "需要密码才能安装"; exit 1; }

[ $# -ge 1 ] || { echo "用法: $0 <App.ipa | App.app>"; exit 1; }
SRC="$1"
[ -e "$SRC" ] || { echo "找不到: $SRC"; exit 1; }

case "$SRC" in
  *.ipa) NAME=$(basename "$SRC") ;;
  *.app) NAME="$(basename "$SRC" .app).app" ;;
  *) echo "只支持 .ipa / .app"; exit 1 ;;
esac

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15 ${ATV_USER}@${ATV_IP}"

echo "==> 检查设备连通性"
$SSH 'id' >/dev/null || { echo "连不上 ${ATV_USER}@${ATV_IP}，检查网络/SSH/越狱状态"; exit 1; }

echo "==> 推送到设备 (${NAME})"
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
  "$SRC" "${ATV_USER}@${ATV_IP}:/var/tmp/${NAME}"

echo "==> 调用 AlmaTrust 安装器"
$SSH "echo '${ATV_PASS}' | sudo -S /bin/sh ${INSTALLER} /var/tmp/${NAME}"

echo
echo "装好了。直接在你的 Apple TV 主屏幕上点图标启动即可。"
echo "（如需命令行启动：ssh ${ATV_USER}@${ATV_IP} 后执行 sudo uiopen --bundleid <bundle-id>）"
