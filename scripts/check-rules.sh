#!/bin/sh
# 轻量级免疫护栏：防已证伪僵尸断言复活、防重复 env 开关、防敏感信息误提交、防断链、防 Python 静默吞错
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

FAIL=0
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=1; }
pass() { printf 'PASS: %s\n' "$1"; }

# 1. 已证伪僵尸断言防复活黑名单
if grep -rnE --exclude=check-rules.sh \
     'MCMAppContainer.*(不存在|does not exist)|CS_INVALID_ALLOWED.*(永不|never)' \
     README.md README.en.md src/ scripts/ docs/zh/CREDITS.md docs/en/CREDITS.md \
     docs/zh/PORTING-TROLLSTORE.md docs/en/PORTING-TROLLSTORE.md 2>/dev/null; then
  fail "命中已证伪僵尸断言（MCMAppContainer 不存在 / CS_INVALID_ALLOWED 永不置位）"
else
  pass "已证伪僵尸断言黑名单 0 命中"
fi

# 2. 旧 env 开关副本防复活（唯一真源：TSLTV_LIB_ONLY）
if grep -rn --exclude=check-rules.sh 'TrollStoreLiteTV_LIB_ONLY' src/ scripts/ tests/ 2>/dev/null; then
  fail "命中已废止环境变量副本 TrollStoreLiteTV_LIB_ONLY（请统一用 TSLTV_LIB_ONLY）"
else
  pass "SSOT 环境变量开关唯一（TSLTV_LIB_ONLY）"
fi

# 3. 个人路径 / 具体设备 jbroot UUID / 私钥敏感扫描
if grep -rnE --exclude=check-rules.sh \
     '/Users/[A-Za-z0-9._-]+/|Dropbox/|ssh-shim/current|\.jbroot-[0-9A-Fa-f]{16}|BEGIN (RSA|PRIVATE|EC|OPENSSH) ' \
     README.md README.en.md NOTICE CHANGELOG.md AGENTS.md docs/ src/ scripts/ tests/ tools/ 2>/dev/null; then
  fail "命中个人敏感路径 / 具体设备 UUID / 私钥模式"
else
  pass "个人敏感信息扫描 0 命中"
fi

# 4. Markdown 相对链接与双语首页引导检查 + Python 静默吞错 AST 检查
python3 - <<'PY' || FAIL=1
import ast, pathlib, re, sys

root = pathlib.Path(".")
broken = []
for p in sorted(root.rglob("*.md")):
    if any(x in p.parts for x in (".git", ".venv", "dist", ".memsearch")):
        continue
    txt = p.read_text(encoding="utf-8", errors="ignore")
    for m in re.finditer(r"\]\(([^)#\s]+)", txt):
        t = m.group(1)
        if t.startswith(("http://", "https://", "mailto:", "#")):
            continue
        if not (p.parent / t).resolve().exists():
            broken.append((str(p), t))
if broken:
    print("FAIL: 发现断链:", broken, file=sys.stderr)
    sys.exit(1)
print("PASS: 全仓 Markdown 相对链接 0 断链")

for f in ("README.md", "README.en.md"):
    top = "\n".join(pathlib.Path(f).read_text(encoding="utf-8").splitlines()[:6])
    if not ("中文" in top and "English" in top):
        print(f"FAIL: {f} 顶部缺少中英文语言切换链接", file=sys.stderr)
        sys.exit(1)
print("PASS: 双语首页语言引导链接齐全")

silent = []
for p in sorted(root.rglob("*.py")):
    if any(x in p.parts for x in (".git", ".venv", "dist")):
        continue
    tree = ast.parse(p.read_text(encoding="utf-8", errors="ignore"))
    for n in ast.walk(tree):
        if isinstance(n, ast.ExceptHandler) and len(n.body) == 1:
            s = n.body[0]
            if isinstance(s, ast.Pass) or (
                isinstance(s, ast.Return) and isinstance(s.value, (ast.Constant, ast.List, ast.Dict))
            ):
                silent.append(f"{p}:{n.lineno}")
if silent:
    print("FAIL: Python 静默吞错:", silent, file=sys.stderr)
    sys.exit(1)
print("PASS: Python AST 静默吞错 0 命中")
PY

[ "$FAIL" -eq 0 ]
