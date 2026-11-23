# 安全策略

## 适用范围

本工具需要在**已越狱**的 Apple TV 上以 root 运行，因此"信任边界"与普通应用不同。
我们尽量把可控面收窄，但请理解它本质上是一个**特权安装器**。

## 设计上的约束

| 项 | 做法 |
|---|---|
| 写入范围 | 仅数据分区与 jbroot：`/Applications`、`/var/tmp`、`/usr/libexec/tsltv`、`/Library/LaunchDaemons`。**不写**只读系统卷 `/rootfs`，不改越狱 basebin，不改内核 |
| 卸载护栏 | 只允许卸载 `installed.tsv` 中 `origin=install` 的条目；越狱自带应用拒绝卸载 |
| 命令注入 | 引擎对动词做白名单；参数中出现 `; \| & $ ( ) < > ' " \`` 一律拒绝；不做 `eval` |
| 网络 | 网页商店无鉴权，默认监听 `0.0.0.0:8787`，仅建议在可信局域网使用 |
| 加密内容 | 不提供任何 FairPlay 解密能力；`cryptid != 0` 的包直接拒绝 |

## 已知取舍

为了让 mobile 身份的电视界面能调用 root 引擎，`/var/run/tsltv` 是 `0755`、
`req.fifo` 与响应文件是 `0666`。**本机任意进程都能调用安装/校验类动词**（不含任意命令执行）。
如果你只用 CLI，可以把它改回 `0700/0600` 恢复严格模式：

```sh
# src/daemon/tsltvd 里这两行
chmod 700 "$RUN"; chmod 600 "$FIFO"
```

## 报告问题

发现安全问题请**不要**开公开 issue，直接邮件联系仓库所有者，或在 GitHub 上用
"Report a vulnerability" 私密上报。请在报告里说明：影响版本、复现步骤、影响范围。
