#!/bin/sh
# 打一个 GitHub Release，并上传「安装包 + 无签名 demo ipa」
#
#   ./scripts/publish-release.sh [tag] [notes-file]
#
# 前置：gh 已登录（gh auth login），且仓库 remote 已指向你的 GitHub 仓库。
set -eu
TAG="${1:-v$(date +%Y.%m.%d)}"
NOTES="${2:-}"
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
cd "$ROOT"

command -v gh >/dev/null 2>&1 || { echo "需要 GitHub CLI：brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "请先 gh auth login"; exit 1; }

# 确保产物是新的
VER="${TAG#v}"
echo "==> 构建 ${VER} 安装包"
VER="$VER" sh scripts/build-deb-local.sh
echo "==> 构建无签名 demo ipa"
sh examples/hello-tvos/build.sh

DEB="dist/trollstore-lite-tv_${VER}_appletvos-arm64e.deb"
IPA="dist/TSLTVDemo-unsigned.ipa"
[ -f "$DEB" ] && [ -f "$IPA" ] || { echo "产物缺失: $DEB 或 $IPA"; exit 1; }

echo "==> 上传 release $TAG"
if [ -n "$NOTES" ] && [ -f "$NOTES" ]; then
  gh release create "$TAG" "$DEB" "$IPA" --title "TrollStore Lite TV $TAG" --notes-file "$NOTES"
else
  gh release create "$TAG" "$DEB" "$IPA" --title "TrollStore Lite TV $TAG" --generate-notes
fi

echo "完成：$(gh release view "$TAG" --json url -q .url 2>/dev/null || echo '(查看仓库 Releases)')"
