#!/bin/sh
# AlmaTrust 公共函数
JBCTL=/basebin/jbctl
BASE=/usr/libexec/almatrust
MANIFEST="$BASE/manifest.txt"
LOGF=/var/log/almatrust.log

mkdir -p /var/log 2>/dev/null

say() { echo "$(date +%H:%M:%S) $*" >>"$LOGF"; }

# 记录一个待重放信任的二进制
manifest_add() {
  case "$1" in
    /Applications/*) ;;
    *) return 0 ;;
  esac
  grep -qxF "$1" "$MANIFEST" 2>/dev/null || echo "$1" >>"$MANIFEST"
}

# 按清单重放：把每个二进制重新写入越狱信任缓存
retrust_all() {
  [ -f "$MANIFEST" ] || { say "no manifest"; return 0; }
  ok=0; bad=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$p" ] || { bad=$((bad+1)); continue; }
    if $JBCTL trustcache add "$p" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      bad=$((bad+1))
    fi
  done <"$MANIFEST"
  say "retrust done ok=$ok bad=$bad"
}
