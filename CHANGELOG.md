# Changelog

## 2.0.5 — 2026-11-23

**修复：网页商店被系统内存上限杀掉**

- 根因：`/api/install` 把整个上传体收进 `NSMutableData` 再落盘，大包（Kodi 这类 200MB+）
  直接撞上本进程的 jetsam 上限，日志显示 `JETSAM_REASON_MEMORY_PERPROCESSLIMIT`；
  又因为 plist 是 `KeepAlive=false`，挂了就不再起来——表现为网页突然打不开
- 修复 1：上传改为**边收边写盘**（64KB 缓冲，`open/write`），内存占用与包大小无关
- 修复 2：网页服务的 plist 改为 `KeepAlive=true` + `ThrottleInterval=10`，被杀后自动恢复
- 补：上传不完整（`Content-Length` 未读满）时删除半截文件并返回 400

## 2.0.4 — 2026-11-23

**可维护性：测试与 CI**

- 新增 `tests/run.sh`：36 条**不需要设备**的断言（脚本语法、plist、CLI 用法、命令注入拦截、
  安装前判定四态、Mach-O 解析、demo ipa 结构与"确实未签名"）
- 新增 `.github/workflows/ci.yml`：shellcheck（warning 即失败）→ 单元测试 → 本地打包 → tag 触发 Release
- 新增 `scripts/build-deb-local.sh`：用 `dpkg-deb --root-owner-group` 在**本机**出包（CI 用同一路径）
- CLI 重构：把安装前判定抽成纯函数 `precheck_verdict`，便于单测；新增 `VERSION` 文件
- 修掉 shellcheck 的全部 warning（含 `for f in $(find …)` 改为读清单文件、
  字符串切片改为 `printf %.20s`、CJK 紧邻变量导致 `$var，` 被当成变量名等问题）

## 2.0.3 — 2026-11-23

**改名与打包重构**（首个公开版本）

- 项目更名 **TrollStore Lite TV**；仓库 `trollstore-lite-tv`
- 内部标识统一：`/usr/libexec/tsltv`、`tsltv` / `tsltvd` / `tsltvweb`、bundle id `com.alma.tsltv`
- 新增命令别名：`tsltv`、`trollstore-lite-tv`、`tsl`
- 修复：`postinst` 中的 launchd job 名与 plist 文件名不一致，导致装完服务不自启
- 修复：`retrust.sh` 以 `installed.tsv` 为唯一来源（此前读的是过时的静态清单）
- 新增 `examples/hello-tvos`（demo app 源码）与无签名 demo ipa 构建脚本
- 打包脚本支持从旧包 `alma-trustlite` 迁移记账清单

## 1.0.12 — 2026-11-23

- `jbroot` 路径改为运行时自动探测（不再硬编码 `.jbroot-<UUID>`）
- `probe` 结果缓存 30 秒，写操作后失效；引擎启动时预热（首屏 13.8s → 1.3s）
- Mach-O 预检重写为 `od` + `awk` 单次扫描（安装 23s → 7s）
- 版本号在 CLI / 网页 / 电视界面三处一致（打包时注入）

## 1.0.0 — 2026-11-23

- 首个可用版本：ad-hoc 双哈希签名 + 内核信任缓存注入 + LaunchServices 注册
- 电视界面 / 网页商店 / CLI 三端共用 `tsltvd` 引擎
- 加密包（`cryptid 1`）安装前拒绝；卸载仅限自装应用
- 自更新、投递目录批量安装、TrollStore RootHelper 兼容层 `tsh`
