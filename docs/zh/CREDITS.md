[中文](CREDITS.md) · [English](../en/CREDITS.md)

# 依赖与致谢

本项目站在这些工作的肩膀上。**它们不属于本仓库**，但缺了它们这套东西跑不起来。

## 运行前提

| 项目 | 作用 | 说明 |
|---|---|---|
| **Relaxin**（roothide 系越狱） | 提供可追加的内核信任缓存 `jbctl trustcache add` | 本项目**所有**能力的前提。没有越狱就没有这条路 |
| **roothide** | Relaxin 的 bootstrap / vroot 框架（`>= 0.1.0-5`） | 提供 `jbroot` 布局、`/usr/libexec` 重定向、LaunchDaemon 补丁 |
| **Procursus** 的 `ldid` / `uicache` | ad-hoc 签名、LaunchServices 注册 | 通过 APT 安装，未打包进本仓库 |

> 关于 Relaxin 的安装与使用请参考其官方发布渠道；本仓库不提供越狱本体，也不对越狱风险负责。

## 设计上借鉴

| 项目 | 借鉴内容 | 许可 |
|---|---|---|
| **TrollStore**（opa334） | RootHelper 的子命令接口、`iTunesMetadata` 用法、"注册为 System/User" 的区分、"app 只是壳 + 特权 helper" 的分层 | MIT（`Copyright (c) 2022-2026 Lars Fröder`） |
| **TrollStore Lite** | 同一套源码的 LITE 编译变体，验证了"注册类型"这一差异的真实存在 | MIT（同上） |

本项目**未复制**上述项目的源码；接口兼容层 `src/fork/tsh` 为独立实现。详见 [NOTICE](../../NOTICE)。

## 明确不依赖

以下能力在本项目中**不存在**，也不打算实现：

- CoreTrust 漏洞利用（CVE-2023-41991）—— 在 tvOS 17.0 上无效，见 [设计取舍](DESIGN-DECISIONS.md)
- FairPlay 解密（不处理加密的 App Store 包）
- 任何绕过 App Store 付费的机制

## 工具链

Xcode / AppleTVOS SDK（编译 tvOS 可执行）、`dpkg-deb`（在设备上打包）、POSIX shell。
