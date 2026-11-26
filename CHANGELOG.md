# Changelog

## Unreleased — 2026-11-26

- **entitlements 与上游 TrollStore RootHelper 对齐**（`opa334/TrollStore · signApp`）：
  - 每个 bundle 的主可执行保留自身 entitlements；只有主 app 完全没有 entitlements 时才回落 `TROLLTROLL.*`；
  - `container-required` 归一（缺省需要容器且无 `no-container`/`no-sandbox` → 写字符串 bundle id，自定义容器 id 原样保留）；
  - TrollStore Lite 额外写 `jb.pmap_cs.custom_trust=PMAP_CS_APP_STORE`；
  - 其余 Mach-O 改用 `ldid -s` 合并式签名，保留各自原 entitlements（不再用一份固定 ent 覆盖所有二进制）。
- **新增 `entfix` 工具**：standalone 实现上述规则，输入/输出全部走 stdin/stdout。tvOS 上 ad-hoc + 信任缓存进程直接读写绝对路径会被 RootHide/vroot 拒绝（`open` 返回 `ENOENT`），因此由受信 shell 负责重定向。
- **嵌套包清理**：安装前递归删除主包及嵌套 appex/framework 的 `SC_Info` / `_CodeSignature`，避免残留 App Store CodeResources 导致注册失败。
- **嵌套加密二进制检测**：`machoscan -e` 按上游 Lite 语义扫描全部 Mach-O（Fat 取 arm64 首选 slice）；主程序加密致命，其余仅告警。
- **安装护栏与权限**：目标已存在且非本工具安装时拒绝覆盖；签名/信任失败自动回滚；安装后按上游 `fixPermissionsOfAppBundle` 设为 `33:33` 属主、文件 `0644`、目录与 Mach-O `0755`。
- **`tsltv verify` 去掉自造门槛**：不再要求 `get-task-allow`，改以「信任缓存命中 + ad-hoc 签名 + 已注册」为通过判据。
- 测试新增 entfix 规则（回落/容器/字符串容器/布尔 false/非 dict 拒绝）与 `machoscan -e`（thin + Fat）覆盖，共 57 条全过。

## 2.1.6 — 2026-11-25

- **修复 roothide vroot 路径桥接根因（trustcache + modinject）**：
  - `trust_one()` 与 `postinst.sh` 改经 `/rootfs/var/tmp`（真实 `/private/var/tmp`）桥接调用 `jbctl trustcache add /var/tmp/...`，修复 vroot shell 中 `/var/tmp` 指向 `.jbroot/var/tmp` 导致新签名二进制（如 `TSLTVDemo`）未被真正写入内核信任缓存的问题。
  - `tsltv mods apply` 改经 `/rootfs/var/tmp` 桥接调用 `modinject`（`O_RDONLY` + 同目录原子 `rename` 换新 inode），并补齐主程序完整 entitlements（不再以空字符串清空权限），彻底解决 2.1.4 以来设备端 `mods apply` 的 `EPERM` 缺陷。
- **全量 Mach-O `retrust`**：`tsltv trust retrust` 改用 `machoscan` 并发重放每个已安装应用的全部 Mach-O（含 Frameworks / `.dylib` / `.so`，实测 7 应用共 161 个 Mach-O 全部通过），重启重新越狱后多动态库应用（如 Kodi）与已注入 mod 均不会缺信任。
- **修复 `installed.tsv` cdhash 失步**：`postinst.sh` 重签 `TrollStoreLiteTV` 后自动同步记账 cdhash；`tsltv probe` 遇记账哈希未命中时自动回查实时文件 cdhash，消除网页/TV 端误报 `信任 ✗`。
- **网页商店首页秒开 + 内置油猴脚本托管**：
  - `tsltvweb :8787` 启用启动预热与后台异步刷新缓存，实测 `GET /` 从 **9.16s** 降至 **0.036s**。
  - 新增本地油猴脚本管理与托管接口（`/api/userscripts.js`、`/api/userscripts/{save,toggle,delete}`，持久化存放在 `/var/mobile/Library/tsltv-userscripts`），支持直接为 YouTube TV（Cobalt）本地离线热加载 TizenTube 及自定义 `.js` 脚本。
- **`selfupdate` 包名校验**：下载后用 `dpkg-deb -f Package` 校验必须为 `trollstore-lite-tv`，拒绝错误或损坏的 `.deb`。
- 测试新增 `machoscan` 断言（45 条全过）。

## 2.1.5 — 2026-11-24

- 卸载只允许 `origin=install`；`adopt` 与来源缺失的旧条目拒绝删除。
- 将 postinst/prerm 独立为共享脚本；签名、trustcache 或 LaunchDaemon 启动失败会让安装明确失败，并为 trustcache 注入补充 `/var/tmp` 路径回退。
- 修复设备 ldid 拒绝 shell 脚本 `tsh`（`Unknown header magic`）：只对 Mach-O helper 和 app 主程序签名。
- 修复升级路径 `prerm` 提前停服和删软链的问题，卸载软件包时保留用户的 `/var/tmp/tsltv-inbox` 投递文件。
- 新增卸载来源回归覆盖（44 条断言），同步版本与文档。
- 修复电视界面自截图状态文本的格式参数错位，确保 `runDir` 显示实际 FIFO 目录。
- 修复 `src/cli/tsltv` 安装权限（`chmod -R a+rX`）与 GPU entitlements（`com.apple.security.iokit-user-client-class`，解决 YouTube TV Cobalt 等 OpenGL ES / Metal 应用因 `EAGLContext initWithAPI:3` 返回 `nil` 崩溃）。
- 修复 `TrollStoreLiteTV.app` 的 tvOS 图标格式（`brandassets` `role=primary-app-icon` + `CFBundlePrimaryIcon=AppIconSmall`），解决主屏不显示图标。
- 修复自带 demo（`examples/hello-tvos`）的 `CFBundleExecutable` 名称错位并补齐反色风格 tvOS 图标（`Assets.car`）；修复 `publish-release.sh` 与 `macos.yml` 的 demo 产物路径。
- 大幅优化网络与大包安装速度：新增单进程 C 扫描器 `machoscan`（扫描 Kodi 12,149 个文件从 ~12 分钟降至 ~2 秒）、`.ipa` 解包后同卷 O(1) `mv` 替代整包 `cp -a`、`plutil -key` 零复制读取与按 PID 隔离 `$WORK`、`trust_one` 跳过必败的 `/Applications` 黑名单探测、多 Mach-O 4 路并发签名入信任；Web 商店 `:8787` 启用 1 MB `SO_RCVBUF` + `TCP_NODELAY` + 512 KB 缓冲写盘 + XHR 实时上传速率/阶段进度显示，且版本号改直读 `VERSION` 不再阻塞 `tsltvd`。


## 2.1.4 — 2026-11-24

- 修复 2.1.3 里 `mods list` 的写法：`continue;;`（无空格）在 bash 下是语法错误，
  会导致整个 CLI 解析失败。改为标准写法并去掉 `ls | grep`（shellcheck 0 warning）

## 2.1.3 — 2026-11-24

**mods 可用了**

- 新增 `tsltv mods list` / `tsltv mods apply <bundle-id> <dylib>`：复制 dylib →
  插 `LC_LOAD_DYLIB` → 重签 → 重新注入信任 → 刷新注册，一条命令完成
- 新增设备端 `modinject`（`src/tools/modinject.m`），与 `tools/inject_dylib.py` 逻辑一致
  （macOS 构建下两者输出 **md5 完全相同**）
- 修 `LC_LOAD_DYLIB` 命令值：此前误加了 `LC_REQ_DYLD`（0x8000000c），
  otool/dyld 会当成未知命令；正确是 `0xC`
- 测试新增"mod 注入"一组（38 条断言）

## 2.1.2 — 2026-11-24

**安装器修复 + mods 原型**

- **修复**：安装 App Store 解密包后无法注册（`uicache: Unable to register`）。
  根因是包内残留 `SC_Info` / `_CodeSignature`（FairPlay 元数据），
  LaunchServices 因此拒绝登记。安装流程现在会在签名前清理它们并修正权限
- 新增 `tools/inject_dylib.py`：向 Mach-O 就地插入 `LC_LOAD_DYLIB`，
  用于原生 dylib mod（机制同 TrollFools）。已在 demo 上验证（`ncmds 24→25`）
- 新增 `docs/zh/MODS.md` 与 `docs/en/MODS.md`

## 2.1.1 — 2026-11-24

**按评审意见修的一批真问题**

- **卸载不干净**：`prerm` 里的主守护进程 label 写成 `com.trollstorelite.tvd`（实际是
  `.daemon`），停不掉；alias 删除列表与 postinst 创建的不一致，卸载后残留
  `/usr/bin/trollstore-lite-tv`、`-cli`、`tsltv-cli`
- **版本来源不唯一**：远程打包脚本默认 `VER=1.0.12`，现在改为读仓库 `VERSION`
- 包显示名两条打包路径不一致（`TrollStoreLiteTV Lite` vs `TrollStore Lite TV`）→ 统一
- **`tsh` 不在 PATH**：文档里写 `tsh install ...` 却只装了 `/usr/libexec/tsltv/tsh` → 补 `/usr/bin/tsh`
- **签名/信任失败被静默吞掉**（`|| return 0` / `|| true`）→ 改为报错并失败
- 电视界面：焦点态加强（白边 + 轻微放大 + 提亮），此前只差一点点背景色
- 网页商店：应用名/版本/bundle id 全部 HTML 转义（防注入），卸载按钮改危险色 + 二次确认
- CLI：`minOS` 判定改为完整比较（17.1 现在会提示）；删掉 `precheck_app` 里的死代码；
  注释从 "unix socket" 改为 FIFO；状态文件字段说明补上 `origin`
- 文档：`<you>` 占位符、`../../releases` 死链、`TSLTV Lite` 旧名、`trollstore-lite` 别名全部修正

## 2.1.0 — 2026-11-23

**命名统一 / 主屏图标 / 网页商店修复 / 双语文档**

- **命名统一**：全项目清除 "Alma"（含 `com.alma.*` 的 bundle id、launchd 标签、legacy 脚本）；
  bundle id 统一为 `com.trollstorelite.tv`（守护进程 `.daemon` / `.web` / `.retrust`）；
  应用包改为 `/Applications/TrollStoreLiteTV.app`；界面标题（电视 + 网页）统一显示全名
  **TrollStore Lite TV**，缩写 `TSLTV` 在 README 术语表里标注
- **主屏图标**：新增 `src/gui/make-icon.swift` 生成 tvOS brandassets（Back/Middle 两层），
  构建时用 `actool` 编成 `Assets.car`；之前主屏没有图标就是因为缺这个
- **网页商店修复（两个真 bug）**：
  1. 整页走一个超长 `stringWithFormat`，CSS/JS 里未转义的 `%` 会把后面的内容截断 →
     列表永远是空的、也只显示到标题。改为 `NSMutableString` 拼接
  2. 页面取数要求 `probe` 退出码为 0，但 `probe` 在有异常项时返回非 0，导致整页静默变空 →
     改为"有输出就用"
- **文档双语**：`docs/zh/` 与 `docs/en/` 各一套（9 篇 + 根 README），顶部互相切换
- 清理设备上的历史测试应用与过期记账（`com.alma.*`）

## 2.0.7 — 2026-11-23

**网页不再被引擎拖死 + 自检脚本修正**

- 首页渲染要同步等引擎的 `probe`，引擎忙（大包安装、`trustcache info`）时整页会一起卡住，
  实测出现过 12s 无响应。改为：`probe` 结果缓存 15s，且最多等 5s，超时就用上一次的数据
- `verify.sh` 第 9 项还在检查早已不存在的 `install.sh`/`trustlib.sh`（改名遗留），
  改为检查 `tsltv` 与 `tsltvd`

## 2.0.6 — 2026-11-23

**网页商店并发处理**

- 根因：accept 循环是串行的（tvOS SDK 禁用 `fork`，当初只能顺序处理），一个大包上传
  期间（20s+）整个网页无响应，看起来像"卡死"
- 修复：每连接一个 detached pthread（线程创建失败时退回串行），大上传不再阻塞其他请求
- 给客户端 fd 设 30s 收发超时，避免半开连接长期占用线程
- FIFO 应答轮询 100ms → 20ms（总超时仍为 180s），首页与操作响应更快

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
- 内部标识统一：`/usr/libexec/tsltv`、`tsltv` / `tsltvd` / `tsltvweb`、bundle id `com.trollstorelite.tv`
- 新增命令别名：`tsltv`、`trollstore-lite-tv`、`tsl`
- 修复：`postinst` 中的 launchd job 名与 plist 文件名不一致，导致装完服务不自启
- 修复：`retrust.sh` 以 `installed.tsv` 为唯一来源（此前读的是过时的静态清单）
- 新增 `examples/hello-tvos`（demo app 源码）与无签名 demo ipa 构建脚本
- 打包脚本支持从旧包 `trollstore-lite-tv` 迁移记账清单

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
