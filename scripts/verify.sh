#!/bin/sh
# TrollStoreLiteTV 验收脚本 —— 只读，不改设备任何东西
#
# 用法:  ./verify.sh [设备IP]
# 输出:  PASS/FAIL 矩阵 + 退出码（全部 PASS 才 0）
#
# 检查项对应目标「在已越狱 tvOS 上启动自签名 app」的每一条硬条件。

set -u
# 需要 ATV_PASS=<设备sudo密码> 才能查到工具版本（可选）

IP="${1:-}"
[ -n "$IP" ] || { echo "用法: $0 <设备IP>"; exit 2; }
JB=/private/var/containers/Bundle/Application/.jbroot-<UUID>
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mobile@$IP"

fail=0
row() { # row <名称> <PASS|FAIL> <证据>
  printf '%-28s %-5s %s\n' "$1" "$2" "$3"
  [ "$2" = "PASS" ] || fail=1
}

VER=""
if [ -n "${ATV_PASS:-}" ]; then
  VER=$($SSH "echo $ATV_PASS | sudo -S -p '' /usr/libexec/tsltv/tsltv version" 2>/dev/null | tr -d '\r' || true)
fi
echo "================ TrollStoreLiteTV 验收 $(date '+%Y-%m-%d %H:%M:%S') ================"
echo "工具版本: ${VER:-unknown}"
echo
echo

# 1. 越狱环境
jb=$($SSH "test -d $JB && echo yes || echo no" 2>/dev/null)
row "越狱 jbroot 存在" "$([ "$jb" = yes ] && echo PASS || echo FAIL)" "$JB"

# 2. 信任缓存可用
tc=$($SSH "echo \$SUDO | sudo -S -p '' $JB/usr/bin/jbctl trustcache info 2>/dev/null | grep -c 'Relaxin trust cache'" 2>/dev/null)
tc=$($SSH "$JB/usr/bin/jbctl trustcache info 2>/dev/null | grep -c 'Relaxin trust cache'" 2>/dev/null)
row "Relaxin 信任缓存可查" "$([ "${tc:-0}" -ge 1 ] && echo PASS || echo FAIL)" "命中 ${tc:-0} 个缓存"

# 3. Kodi 已装
k=$($SSH "test -x $JB/Applications/Kodi.app/Kodi && echo yes || echo no" 2>/dev/null)
row "Kodi 已安装" "$([ "$k" = yes ] && echo PASS || echo FAIL)" "$JB/Applications/Kodi.app"

# 4. Kodi 是 ad-hoc 自签（无 Apple Team ID）
sig=$($SSH "ldid -h $JB/Applications/Kodi.app/Kodi 2>/dev/null" 2>/dev/null)
echo "$sig" | grep -q 'flags=0x2(adhoc)' && s1=PASS || s1=FAIL
row "Kodi 为 ad-hoc 自签" "$s1" "$(echo "$sig" | grep -o 'flags=0x2(adhoc)' | head -1)"
echo "$sig" | grep -q 'TeamIdentifier=not set' && s2=PASS || s2=FAIL
row "无 Apple 证书" "$s2" "$(echo "$sig" | grep -o 'TeamIdentifier=.*' | head -1)"

# 5. cdhash 在内核信任缓存中
cd=$($SSH "ldid -h $JB/Applications/Kodi.app/Kodi 2>/dev/null | sed -n 's/.*CandidateCDHash sha256=//p' | head -1" 2>/dev/null)
hit=$($SSH "$JB/usr/bin/jbctl trustcache info 2>/dev/null | grep -ic '${cd}'" 2>/dev/null)
row "cdhash 在信任缓存中" "$([ "${hit:-0}" -ge 1 ] && echo PASS || echo FAIL)" "$(printf %.20s "$cd")… 命中 ${hit:-0}"

# 6. Kodi 进程活着
ps=$($SSH "ps ax -o pid,etime,command 2>/dev/null | grep 'Applications/Kodi.app/Kodi' | grep -v grep | head -1" 2>/dev/null)
[ -n "$ps" ] && p1=PASS || p1=FAIL
row "Kodi 进程存活" "$p1" "$(echo "$ps" | awk '{print "PID "$1" 已运行 "$2}')"

# 6b. 关键：父进程必须是 launchd(1)，证明是"系统启动"而非 SSH 里手动 exec
kpid=$(echo "$ps" | awk '{print $1}')
kppid=$($SSH "ps -o ppid= -p ${kpid:-0} 2>/dev/null | tr -d ' '" 2>/dev/null)
row "由系统 launchd 启动" "$([ "${kppid:-x}" = "1" ] && echo PASS || echo FAIL)" "PPID=${kppid:-?} (1=launchd)"

# 7. 安装器部署
inst=$($SSH "test -x /usr/libexec/tsltv/tsltv && test -x /usr/libexec/tsltv/tsltvd && echo yes || echo no" 2>/dev/null)
row "TrollStore 式安装器在位" "$([ "$inst" = yes ] && echo PASS || echo FAIL)" "/usr/libexec/tsltv/tsltv"

# 8. 屏幕是否亮（决定能否验证启动）
echo
echo "--- 启动验证前提 ---"
# 注意: 必须 grep -v grep，否则 grep 自己的命令行会自匹配（本项目踩过的坑）
w=$($SSH "uiopen --bundleid com.apple.TVSettings >/dev/null 2>&1; sleep 4; ps ax -o command 2>/dev/null | grep 'TVSettings.app/TVSettings' | grep -v grep | grep -c ." 2>/dev/null)
if [ "${w:-0}" -ge 1 ]; then
  echo "PASS  显示在线，可以验证启动（uiopen 有效）"
else
  echo "SKIP  显示离线：uiopen 空转（连系统 app 都拉不起来），启动类结论无法判定"
fi

echo
[ "$fail" -eq 0 ] && echo "结果: 全部 PASS" || echo "结果: 有 FAIL"
exit $fail
