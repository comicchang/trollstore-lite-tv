[中文](FULL-TROLLSTORE-GAP.md) · [English](../en/FULL-TROLLSTORE-GAP.md)

# 现状总结与原版 TrollStore（免越狱持久版）Gap 分析

> 写于 2026-11-25。整理当前双项目基线，并系统拆解从 **TrollStore Lite TV**（越狱态内核信任缓存）迈向**原版 TrollStore for tvOS**（免越狱、重启后仍永久生效）的全部技术缺口、已修正认知、风险闸门与验证路径。

---

## 1. 当前现状基线（As-Is）

截至 2026-11-25，两个独立开源项目均已完成开发、实机验收并公开发布（CI 全绿）：

| 项目 | 版本 / 许可 | 当前能力 | 真机验收证据 |
|---|---|---|---|
| [**trollstore-lite-tv**](https://github.com/comicchang/trollstore-lite-tv) | **v2.1.6** · MIT | 越狱 tvOS 17.x 安装器（TV 界面 + `:8787` 网页商店 + CLI `tsltv`）：`machoscan` 快速扫描、4 路并发签名、全量 `retrust`、设备端 `mods apply`、GPU IOKit entitlements、内置 `:8787` 油猴脚本托管 | 45/45 单测 PASS；Apple TV 4K (`AppleTV14,1`, tvOS 17.0 + Relaxin) 上 4K 截屏实证 **Kodi 21.3 / YouTube TVL / tvOS Browser / TrollStore Lite TV** 全部正常进入界面；`tsltv verify` 7/7 PASS；`retrust` 161/161 Mach-O PASS |
| [**tvos-cobalt-userscript**](https://github.com/comicchang/tvos-cobalt-userscript) | **v0.1.0** · MIT | 面向 Cobalt 网页壳 tvOS 应用的洁净室油猴补丁工具：强制校验 `cryptid == 0`、声明式 JSON Profile、本机离线热加载 `127.0.0.1:8787/api/userscripts.js` + CSP 放行、多开改 Bundle ID、macOS 本机图标反色 | 10/10 单测 PASS；真机 4K 截屏实拍 `TizenTube 设置` 面板弹出且网页端拉取计数递增 |

**当前方案的唯一结构性限制**：
- `TrollStore Lite TV` 的代码信任判据是 Relaxin 越狱注入的**内核信任缓存（`jbctl trustcache add`）**。
- Apple TV 整机断电/重启后，内核信任缓存清空，必须重新运行一次 Relaxin 越狱（重启越狱后 `com.trollstorelite.tv.retrust` 会自动重放全部 161 个 Mach-O）。
- **在未越狱态下**，已安装的应用无法直接启动。

---

## 2. 关键认知修正（对照 `straight-tamago/TrollStore-tvOS` 源码核查）

早期文档（[PORTING-TROLLSTORE.md](PORTING-TROLLSTORE.md)、[DESIGN-DECISIONS.md](DESIGN-DECISIONS.md)）中有两条结论需要修正/复核：

1. **已修正：`posix_spawn` 与 `MCMAppContainer` 并非在 tvOS 运行时缺失**
   - 核查 [`straight-tamago/TrollStore-tvOS`](https://github.com/straight-tamago/TrollStore-tvOS) 的 `RootHelper/Makefile` 与 `Shared/TSUtil.m` 确认：
     - Xcode 公开 `AppleTVOS.sdk` 仅在**头文件层**将 `posix_spawn*` 标为 `API_UNAVAILABLE(tvos)` 并隐藏了 `MobileContainerManager` 等私有框架；
     - 使用 Theos patched tvOS SDK（`appletv:clang:16.4:14.0`）或 `extern` / `dlsym` 声明，链接 `MobileContainerManager`、`FrontBoardServices`、`RunningBoardServices`、`BackBoardServices`、`SpringBoardServices` 后，`posix_spawnattr_set_persona_uid_np` 与 `MCMAppContainer` 在 tvOS 上可以正常编译与调用。
2. **待严格复核：tvOS 17.0 上 CoreTrust 2（CVE-2023-41991）是否真正失效**
   - 早期记录称「伪造成功但 `CS_INVALID_ALLOWED` 永不置位」，但 `straight-tamago/TrollStore-tvOS`（v2.1）明确声明支持 `tvOS 17.0`（且 CVE-2023-41991 在 17.0.1 才被修补）。
   - 早期失败存在三种常见假阴性原因：① 未使用完整的 `ChOma` `fastPathSign` 双签名者 CMS 模板；② 注册为 `User` 而非 `System` 被 FrontBoard 的 `libmis` 拦下；③ 在已越狱态测试时受 roothide/AMFI Hook 干扰。
   - **结论**：必须先做一次严谨的 Gate 1 最小验证，再决定是否投入完整工程开发。

---

## 3. 逐项 Gap 矩阵（TrollStore Lite TV vs 原版免越狱 TrollStore）

| # | 维度 | 当前现状（TrollStore Lite TV v2.1.6） | 目标形态（原版免越狱 TrollStore for tvOS） | Gap 说明与难度 |
|---|---|---|---|---|
| **G1** | **代码信任机制** | `ldid` ad-hoc 双哈希 + `jbctl trustcache add`（依赖越狱） | **CoreTrust 2（CVE-2023-41991）** 双签名者 CMS 伪造（`ChOma` + `fastPathSign`），仅限 tvOS ≤ 17.0 | **核心 Gap（高）**：需实证 `AppleTV14,1` tvOS 17.0 未越狱态内核是否放行 |
| **G2** | **特权执行引擎（RootHelper）** | Shell 脚本 `tsltv` + `tsltvd`（依赖 Procursus `ldid`/`uicache`/`unzip`/`plutil` 与 `$JB`） | **单文件自包含原生 arm64 `RootHelper`**（静态/内嵌 `ChOma` + `fastPathSign` + `libarchive` + `OpenSSL` + `LSApplicationWorkspace`，经 CoreTrust 签名） | **工程 Gap（中-高）**：未越狱重启后所有越狱工具链都不存在，必须零外部 shell 依赖 |
| **G3** | **App 提权拉起机制** | FIFO（`/var/run/tsltv/req.fifo`）交给 root LaunchDaemon `tsltvd` | App 携带 `com.apple.private.persona-mgmt`，直接 `posix_spawn` + `posix_spawnattr_set_persona_uid_np(0)` 拉起 `RootHelper` | **工程 Gap（中）**：未越狱态没有越狱 LaunchDaemon；需用 patched SDK / `dlsym` 调用 `posix_spawn` |
| **G4** | **容器与注册** | 放进 `$JB/Applications/*.app` + Procursus `uicache -p` | 经 `MCMAppContainer` 部署到原生 `/var/containers/Bundle/Application/<UUID>`，调用 `LSApplicationWorkspace` 注册为 `System`（携带 `MobileInstallationHelperService` 等完整 entitlements） | **工程 Gap（中）**：需在未越狱态实测 `MCMAppContainer` 与 `LSApplicationWorkspace` 行为 |
| **G5** | **Persistence Helper（图标缓存自救）** | 无须寄生（重启后由 Relaxin 越狱 + `retrust` 恢复） | 系统重建图标缓存后所有 CoreTrust App 会退回 `User` 态打不开，需把 `PersistenceHelper` 寄生到某个 tvOS 系统 App 中，未越狱态一键 `Refresh App Registrations` | **高风险 Gap（高）**：tvOS 17.0 无 USB 救砖且不可降级，替换系统 App 必须严格备份与验证 |
| **G6** | **首次安装引导（Bootstrap）** | 通过 `dpkg -i`（已有 Relaxin 越狱） | 未越狱设备需 kernel/installd 漏洞首装；**但我们已有 Relaxin 越狱，可直接由 Relaxin 完成首装，装完后脱离越狱永久运行** | **已就绪（零 Gap）** |
| **G7** | **前端 UI 与生态** | 已有成熟 TV UI + 39 ms 网页商店 `:8787` + 实时进度上传 + 油猴托管 | 可**直接复用**（仅把底层调用从 `ATRun()` FIFO 切为双后端：CoreTrust 模式走 `spawnRoot`，越狱模式走 FIFO） | **已就绪（复用优势）** |
| **G8** | **GPU / 特殊权限支持** | 已验证补齐 `com.apple.security.iokit-user-client-class`（AGX/IOAccel/IOSurface）与 `chmod -R a+rX` | `fastPathSign` 签名时自动保留/合并目标 App 所需 entitlements（含 OpenGL ES / Metal GPU 权限） | **已就绪（复用经验）** |

---

## 4. 低风险推进路线（三道 Gate，严格先验证后动真机）

由于 `AppleTV14,1` 的 tvOS 17.0 属于绝版固件且无 USB 恢复口，必须按 **“离线静态 → 虚拟调试 → 最小单点真机 → 全量工程”** 顺序设立 3 道闸门：

### Gate 1：CoreTrust 2 可行性定生死（零真机变砖风险）

1. **离线内核/KEXT 静态核查**：
   - 获取 `AppleTV14,1` tvOS 17.0 官方 IPSW，提取内核缓存中的 `CoreTrust` / `AMFI` 相关函数，静态确认 CVE-2023-41991 的多签名者校验漏洞在该 build 中确未修补。
2. **Mac 虚拟机预演（[`Lakr233/vphone-cli`](https://github.com/Lakr233/vphone-cli)）**：
   - 在 Apple Silicon Mac 上借助 `vphone-cli`（基于 macOS `Virtualization.framework`）验证 `ChOma` + `fastPathSign` 签名流程、`dlsym`/`extern` 调用 `posix_spawn` + `persona` 提权、以及 `MCMAppContainer` + `LSApplicationWorkspace` 注册代码。
   - **版本限制（按当前最新版本）**：`vphone-cli` 的 tvOS 预设仅支持约 **tvOS 26.6–27.x**（tvOS 27 左右；tvOS 27+ 需 macOS 27 宿主机），**不支持启动 tvOS 17.x**，因此仅适合用于新固件研究与通用 API 演练，无法直接复现 tvOS 17.0 的内核行为。
3. **真机最小 PoC（不碰任何系统 App）**：
   - 用 `fastPathSign` 签一个极简 `hello-ct` CLI 与极简 `HelloCT.app`（**绝对不调用 `jbctl trustcache add`**）。
   - 验证在**无 trustcache 条目**时，`HelloCT` 能否在设备上直接执行、以及在 `Type: System` 注册下能否拉起；
   - 确认通过后，做一次干净整机重启（**不运行 Relaxin**），验证未越狱态直接点击 `HelloCT.app` 能否打开。

> **Gate 1 止损线**：若离线核查或无 trustcache PoC 证明 `AppleTV14,1` tvOS 17.0 确实无法通过 CoreTrust 2 放行，则**立即停止原版方向**，避免无效投入，专注维护 `TrollStore Lite TV`。

### Gate 2：构建自包含 tvOS `RootHelper` 并对接双后端前端

- 搭建 Theos + patched tvOS SDK 构建环境（含 `libarchive`、`libcrypto`、`ChOma`、`fastPathSign`）。
- 实现自包含 `trollstorehelper-tv`（支持 `install` / `uninstall` / `refresh` / `refresh-all` / `enable-jit`），补齐 `RootHelper/entitlements.plist` 与 GPU IOKit 权限保留。
- 复用现有 `TrollStoreLiteTV.app` 与 `:8787` 网页商店，设计统一抽象层：
  - **永久模式（CoreTrust）**：未越狱可用，走 `spawnRoot(trollstorehelper-tv)`；
  - **越狱模式（TrustCache）**：兼容 tvOS 17.0.1+ 与已有 `Relaxin` 环境，走 `tsltvd` FIFO。

### Gate 3：tvOS Persistence Helper 闭环验证

- 盘点 tvOS 17.0 上可安全替换且可随时重新恢复的系统/预装 App，确定 Persistence Helper 寄生目标。
- 在严格保留原二进制备份的前提下，测试「触发图标缓存刷新 → App 退回 User → 打开 Persistence Helper 一键恢复 System 注册 → 重启验证」完整闭环。

---

## 5. Gate 1 预演实测结果（2026-11-25，纯只读零风险探针）

我们在当前 Mac（Apple Silicon `arm64`，macOS `27.2.1`）与真机 Apple TV 4K（`AppleTV14,1`）上完成了无修改、零风险的环境与运行时 API 预演，得到以下确定事实：

### 5.1 固件与宿主机检查

- **真机精确版本**：`AppleTV14,1` · **tvOS 17.0（Build `21J354`）** · `xnu-10002.3.3~1/RELEASE_ARM64_T8110`（2023-08-15），确认是 **17.0 初始正式版**（在 17.0.1 修补 CVE-2023-41991 之前）。
- **Mac 宿主机现状**：`arm64`，剩余磁盘 `60 GiB`，但 **`SIP = enabled`**；尚未安装 `theos`、`pkg-config`、`libarchive`、`openssl`、`ldid`。
  - 如要使用 [`Lakr233/vphone-cli`](https://github.com/Lakr233/vphone-cli) 在本机起虚拟机，除需在 macOS 恢复模式降低 SIP 并预留 ~35–40 GB 磁盘空间外，**按当前最新版本限制**其 tvOS 预设仅支持约 **tvOS 26.6–27.x**（tvOS 27 左右），无法用于 tvOS 17.0 固件复现。

### 5.2 真机只读运行时探针实测（全部通过，无需 Theos 即可动态绑定）

使用本机标准 Xcode `AppleTVOS.sdk` 编译只读探针（`dlopen` + `dlsym`）在 Apple TV 4K（`21J354`）上实测结果：

| 检查项 | 实测结果 | 意义 |
|---|---|---|
| `posix_spawn` / `posix_spawnattr_init` / `posix_spawnattr_destroy` | ✅ `OK`（`0x1849b9bb8` 等） | 运行时完整存在，SDK 标 unavailable 仅是头文件限制 |
| `posix_spawnattr_set_persona_np` / `_uid_np` / `_gid_np` | ✅ `OK`（`0x1849b9410` / `0x1849b94dc` / `0x1849b950c`） | App 侧可直接提权拉起 root `RootHelper`（G3 可行） |
| `MobileContainerManager`（`MCMAppContainer` / `MCMAppDataContainer`） | ✅ `dlopen=OK`，两个类均 `OK` | 原生容器部署 API 在 tvOS 17.0 真实可用（G4 可行） |
| `CoreServices` `LSApplicationWorkspace`（`registerApplicationDictionary:withObserverNotification:` 等 5 个 selector） | ✅ 全部 `OK` | 可脱离 Procursus `uicache` 直接完成 System 注册 |
| `FrontBoardServices` / `RunningBoardServices` / `BackBoardServices` / `SpringBoardServices` / `MobileInstallation` | ✅ 全部 `dlopen=OK` | 全部私有框架齐备 |

### 5.3 关键新发现：tvOS 17.0 缺少 iOS 风格的「可卸载系统 App」

实测扫描 `/var/containers/Bundle/Application/*/*.app` 与 `/rootfs/Applications/*.app` 发现：
- tvOS 17.0 所有自带系统应用（`Podcasts`、`AppleTV`、`Fitness`、`FaceTime`、`TVMovies`、`TVMusic`、`TVHomeSharing` 等）**全部位于只读密封卷 `/rootfs/Applications/`**，没有任何一个像 iOS `Tips` 那样位于可写 `/private/var/containers/Bundle/Application/` 的可卸载 `System` App（可写容器内唯一的 Apple 应用只有从商店装的 `TestFlight.app`，属于 `User` 类型）。
- **结论（直接影响 G5 架构）**：
  - 在正常重启（未触发系统全量图标缓存重建）场景下，CoreTrust 签名的 `System` App 仍可免越狱直接启动；
  - 但一旦触发全量图标缓存重建，tvOS 17.0 上**没有安全的 iOS `Tips` 式免越狱 Persistence Helper 寄生位**，此时需要重新跑一次 Relaxin 越狱（或通过 Relaxin 恢复注册）。这大幅降低了动系统 App 的诱因与变砖风险。

---

## 6. 合规与开源许可证注意事项

1. **许可证兼容**：
   - [`opa334/TrollStore`](https://github.com/opa334/TrollStore) 与 [`straight-tamago/TrollStore-tvOS`](https://github.com/straight-tamago/TrollStore-tvOS) 主体为 MIT，但部分文件（如 `RootHelper/uicache.m`）为 CoolStar 的 **BSD-4-Clause**，且依赖 [`OpenSSL`](https://github.com/openssl/openssl)（Apache-2.0）、[`libarchive`](https://github.com/libarchive/libarchive)（BSD-2-Clause）、[`opa334/ChOma`](https://github.com/opa334/ChOma)（MIT）。
   - 若直接复用上游代码，必须在 `LICENSE` / `NOTICE` 中逐项保留原版权与许可证文本；若独立重写，须保证洁净室边界。
2. **外部引用工具边界**（仅文档引用，均不打包）：
   - [`owngoal-dev/Relaxin`](https://github.com/owngoal-dev/Relaxin)（MIT）
   - [`roothide`](https://github.com/roothide) / [`Procursus`](https://github.com/ProcursusTeam/Procursus)（[`ldid`](https://github.com/ProcursusTeam/ldid)、[`uikittools-ng`](https://github.com/ProcursusTeam/uikittools-ng)）
   - [`Lakr233/vphone-cli`](https://github.com/Lakr233/vphone-cli)（MIT；按当前最新版本仅支持约 tvOS 26.6–27.x / tvOS 27 左右，不支持 tvOS 17.x）
   - [`majd/ipatool`](https://github.com/majd/ipatool)（MIT）
   - [`EthanArbuckle/fairplay-decrypt`](https://github.com/EthanArbuckle/fairplay-decrypt)（GPL-3.0）
3. **禁止入库项**：任何 Apple 官方 IPSW / 内核镜像 / 证书私钥（如 `.p12`）/ 第三方 `.ipa` / FairPlay 凭据一律不得提交进公开仓库。
