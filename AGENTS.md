# AGENTS.md — TrollStore Lite TV 仓库协作基准

开发、排障或评审前，请先阅读纯 `[H]` 用户规格罗盘：[docs/GOLDEN-RULES.md](docs/GOLDEN-RULES.md) 与 [docs/TROUBLESHOOTING-PLAYBOOK.md](docs/TROUBLESHOOTING-PLAYBOOK.md)。

## 防自造规则铁律

1. **修根因不加闸**：遇失败只许修根因、有界退避重试、记可观测证据；禁止私自新增硬拒闸、长冷却、次数硬上限（用户明确**不设重试与讨论上限**）、多余局域网安全限制或默认关闭开关。
2. **红宝书只读 + 增量更新**：常规开发提交禁止修改 `docs/GOLDEN-RULES.md`；仅在用户明确指示时按「增量维护、以新覆旧」更新，必须带 `[H]` 来源并刷新头部版本与水位线（Watermark）。
3. **四位一体清障**：删除或修正过时规则/断言时，必须同步清理全部副本、衍生补丁、锁死旧字面量的测试与幽灵注释，防止下一任 Agent 复活。

## 最小充分本地校验

```sh
./tests/run.sh
./scripts/check-rules.sh
shellcheck -S warning src/cli/tsltv src/daemon/tsltvd src/daemon/retrust.sh src/fork/tsh scripts/*.sh scripts/package/*.sh tests/run.sh tests/stage1/run.sh tests/stage2/build.sh
```
