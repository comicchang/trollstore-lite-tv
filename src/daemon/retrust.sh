#!/bin/sh
# 每次越狱启动时由 com.trollstorelite.tv.retrust 拉起：按「记账清单」重放信任缓存。
#
# 之前这里用的是 trustlib.sh + manifest.txt（早期安装器留下的 86 行静态清单），
# 已经过时：清单里有些路径早就不存在，而新装的应用又不在清单里。
# 现在统一以 installed.tsv（tsltv 的记账文件）为唯一来源。

AT=/usr/libexec/tsltv/tsltv

echo "daemon start $(date '+%Y-%m-%d %H:%M:%S')"

if [ ! -f /usr/libexec/tsltv/installed.tsv ]; then
  echo "no state file, nothing to replay"
  echo "daemon exit"
  exit 0
fi

"$AT" trust retrust
echo "daemon exit $(date '+%Y-%m-%d %H:%M:%S')"
