[中文](ARCHITECTURE.md) · [English](../en/ARCHITECTURE.md)

# 架构

## 1. 一条原理

tvOS 决定一个二进制能否执行，看的是**内核信任缓存里的 cdhash**（20 字节 sha256），
与文件路径、与有无 Apple 签名都无关。越狱（Relaxin/roothide）提供了一份可追加的信任缓存，
只要把 cdhash 加进去，系统就会像对待正版应用一样执行它。

因此整套方案是三件事：

```
ldid -S<ent> -Cadhoc -Hsha1 -Hsha256   →   jbctl trustcache add <macho>   →   tsreg register <app>
```

### 三个必要条件（缺一条就静默退出、零日志）

| 条件 | 说明 |
|---|---|
| **双哈希签名** | 只签 sha1 或只签 sha256 会导致进程秒退，且没有任何日志 |
| **entitlements 沿用原签名** | 与上游 `opa334/TrollStore` RootHelper 的 `signApp` 一致：每个 bundle 的主可执行保留自身 entitlements；只有主 app 完全没有 entitlements 时才回落 `TROLLTROLL.*`。不再强制注入 `get-task-allow` / `application-identifier` |
| **容器字段归一** | 缺省视为需要容器；没有 `no-container` / `no-sandbox` 时写 `container-required=<bundle-id>`（字符串），自定义容器 id 原样保留 |
| **Lite 信任级** | TrollStore Lite 额外写 `jb.pmap_cs.custom_trust=PMAP_CS_APP_STORE`（PMAP_CS 设备以 App Store 信任级运行 ad-hoc 签名） |
| **GPU IOKit entitlements**（OpenGL ES / Metal 应用） | `com.apple.security.iokit-user-client-class` 原本就在 App Store / 解密包的 entitlements 里，保留即可；只有源包完全没有 entitlements 时回落的 `TROLLTROLL.*` 不含该键 |

> 运行判据：cdhash 在内核信任缓存 + ad-hoc 签名 + 已注册。`tsltv verify` 不再把 `get-task-allow` 当作硬门槛（上游同样保留各应用原样 entitlements）。

---

## 2. 组件

```
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ TrollStoreLiteTV.app│   │ tsltvweb │   │  tsltv   │   三个前端
│  (UIKit)     │   │  (:8787)     │   │  (POSIX sh)  │
└──────┬───────┘   └──────┬───────┘   └──────┬───────┘
       │   FIFO 请求       │                  │ 直接 exec（root）
       └────────┬──────────┘                  │
                ▼                             │
        ┌────────────────┐                    │
        │  tsltvd    │◀───────────────────┘（可选：`tsltv remote`）
        │  root, launchd │
        └────────┬───────┘
                 ▼
   ldid · jbctl trustcache · tsreg（MCM 容器 + LaunchServices） · /Applications · installed.tsv
```

| 组件 | 语言 | 职责 |
|---|---|---|
| `src/tools/tsreg.m` | ObjC | 原生注册：MCM 数据/插件/App Group 容器 + `LSApplicationWorkspace` 注册/注销 + Info.plist 补丁 |
| `src/cli/tsltv` | POSIX sh | 全部业务逻辑：解包、预检、签名、信任、注册、记账 |
| `src/daemon/tsltvd` | POSIX sh | 常驻引擎：从 FIFO 收命令、执行、写回结果 |
| `src/web/main.m` | ObjC | 网页商店（HTTP 服务 + 内置页面） |
| `src/gui/main.m` | ObjC/UIKit | 电视界面 |
| `src/fork/tsh` | POSIX sh | TrollStore `RootHelper` 接口兼容层 |
| `src/tools/wake.m` | ObjC | HID 按键注入（唤醒休眠的电视） |
| `src/daemon/retrust.sh` | POSIX sh | 开机按清单重放信任 |

**状态文件** `/usr/libexec/tsltv/installed.tsv`（唯一事实来源）：

```
bundle_id ⇥ app_path ⇥ cdhash ⇥ installed_at ⇥ origin(install|adopt)
```

卸载只允许作用于这张表里的条目 —— 这是防止误删系统应用/其他应用的唯一护栏。

---

## 3. 为什么是 FIFO

tvOS 上有两条硬限制，把常见做法全堵死了：

| 尝试 | 实测结果 |
|---|---|
| launchd `Sockets` + `inetdCompatibility` / `OnDemand` | socket 建得出来，但连接到来时 `runs = 0` —— launchd **从不** spawn 子进程 |
| 进程内 `fork()` / `posix_spawn_file_actions_*` | SDK 标注 `unavailable`，编译直接失败 |
| `popen()` | 内部依赖 `/bin/sh`，在某些 vroot 下不存在 |

于是特权操作只能由 **launchd 托管的 shell 进程**完成，前端通过**文件 I/O** 与它通信：

```
客户端 → /var/run/tsltv/req.fifo   "<id>\t<动词> [参数…]"
引擎   → <id>.out（stdout+stderr 合并）/ <id>.rc（退出码）/ <id>.done（完成标记）
客户端 → 轮询 <id>.done，读回结果后清理
```

安全约束：动词白名单（`install` / `uninstall` / `verify` / `probe` / `trust` / `refresh` /
`registration` / `version` / `inbox*` / `selfupdate` / `launch`），
命令中出现任何 shell 元字符（`; | & $ ( ) < > ' " \``）直接拒绝，不做 `eval`。

**性能**：单次往返约 1.5 秒固定开销（引擎是串行 shell）。因此：

- `probe`（列表数据）在引擎侧缓存 **30 秒**，写操作后自动失效
- 引擎启动时**预热** `probe` 缓存，界面打开即热（13.8s → 1.3s）
- Mach-O 预检用 `od` 一次性 dump + `awk` 线性扫（避免每个 load command fork 一次 `od`，16.8s → 亚秒）

---

## 4. 安装一个 ipa 的完整流程

```
1. 解包（unzip）到 /var/tmp/tsltv.work/unpack
2. 读 iTunesMetadata.plist（可选）→ 显示原始应用名/版本
3. 预检：解析主可执行头的 LC_BUILD_VERSION / LC_ENCRYPTION_INFO_64
     - cryptid != 0  → 拒绝（加密包）
     - platform = 2  → 警告（iOS 包）
     - minos > 17.0  → 警告（系统版本过高）
4. 复制到 /Applications/<Name>.app，递归清理主包与嵌套 appex/framework 的 SC_Info / _CodeSignature；按上游 applyPatchesToInfoDictionary 打补丁（SBAppUsesLocalNotifications=1、剥离真正系统应用占用的 URL scheme）
5. 按 bundle 读取原有 entitlements 并归一容器字段（主 app 为空才回落 TROLLTROLL.*，Lite 写 pmap_cs）
6. 遍历所有 Mach-O（主可执行 + Frameworks + PlugIns + appex）：
     bundle 主可执行用各自 entitlements 覆盖签名；其余二进制 ldid -s 合并式签名（保留原 ent）
     → jbctl trustcache add
7. 权限对齐（33:33 属主；文件 0644，目录与 Mach-O 0755）→ tsreg register：
     MCM 数据容器 + LS 字典（Entitlements / 插件表 / App Group / 容器化字段），默认 System
8. 写入 installed.tsv，并在 app 内写 `.tsltv-tsreg` 标记（refresh / mods 据此不迁移旧 uicache 应用的容器）
```

路径黑名单：`jbctl trustcache add` 会静默拒绝 `/var/containers/Bundle/Application/**`
下的路径，因此若遇到，先复制到 `/var/tmp` 再加（cdhash 与路径无关），再搬回去。

---

## 5. 启动顺序与权限

| 进程 | 用户 | 启动方式 | 说明 |
|---|---|---|---|
| `tsltvd` | root | LaunchDaemon，`RunAtLoad` | 常驻，串行处理请求 |
| `tsltvweb` | root | LaunchDaemon，`RunAtLoad` | 监听 8787 |
| `com.trollstorelite.tv.retrust` | root | LaunchDaemon，`RunAtLoad` | 越狱启动时按清单重放 |
| `TrollStoreLiteTV.app` | mobile | 主屏启动 | 只通过 FIFO 请求引擎，自己不做特权操作 |

launchd 的坑：plist 若写成"直接 exec 脚本 + `KeepAlive=true`"，会报 `EX_CONFIG(78)` 从不启动。
必须照下面这个形状：

```xml
<key>ProgramArguments</key><array><string>/bin/sh</string><string>/usr/libexec/…/tsltvd</string></array>
<key>ProcessType</key><string>Background</string>
<key>KeepAlive</key><false/>
<key>StandardOutPath</key><string>/var/log/…</string>
```

---

## 6. 安全模型

- **写入范围**：只有数据分区与 jbroot（`/Applications`、`/var/tmp`、`/usr/libexec/tsltv`、
  `/Library/LaunchDaemons`）。不写 `/rootfs`（只读系统卷）、不改 basebin、不改内核。
- **不可逆操作**：`uninstall` 只作用于 `installed.tsv` 内 `origin=install` 的条目；
  越狱自带应用（`adopt` 进来的）拒绝卸载。
- **命令注入**：引擎对动词做白名单、对参数拒绝 shell 元字符，不做字符串求值。
- **权限**：FIFO 目录 `0755`、`req.fifo` 与响应文件 `0666` —— 让 mobile 身份的 GUI 能调用。
  这是有意的取舍：本机任意进程都能调用这几个**安装/校验类**动词（不含任意命令执行）。
  若只用 CLI，可把 `tsltvd` 里那两处 `chmod` 改回 `700/600` 恢复严格模式。
- **不提供解密**：加密包（购买版）一律拒绝，本项目不含任何 FairPlay 绕过能力。
