[中文](ROADMAP.md) · [English](../en/ROADMAP.md)

# 从「能装能跑」到「像个产品」：TSLTV 路线图

写于 2026-11-23 05:40。当前已上线的是 **CLI 层**（`/usr/libexec/tsltv/tsltv`），
下面按「现在有什么 / 下一层做什么 / 哪些根本做不到」三块讲。

---

## 0. 现在有什么（已验证）

一条命令完成：下载 → 解包 → 逐 Mach-O 自签 → 写内核信任缓存 → 注册 → 记账。

```sh
sudo tsltv doctor                     # 环境自检
sudo tsltv install /path/App.app       # 从本地 app/ipa 安装
sudo tsltv install-url http://…/x.ipa  # 从直链安装（TrollStore 的典型用法）
sudo tsltv adopt --all                 # 把已装的 app 纳入管理（不重签）
sudo tsltv list                        # 清单
sudo tsltv verify [bundle-id…]         # 校验：信任命中 / adhoc / 注册 / hrcfb
sudo tsltv uninstall <bundle-id>       # 只允许卸载本工具装过的
sudo tsltv trust retrust               # 按清单重放信任
```

实测（2026-11-23 05:35）：

```text
==> 下载 http://192.168.1.10:8899/TSLTVCli.ipa
100  6475  100  6475    0     0   301k      0 --:--:-- --:--:-- --:--:--
==> 签名 1 / 信任 1 / 失败 0
PASS  com.trollstorelite.tv.cli    cdhash=b914ffb10f3c…  origin=install hrcfb=1
全部通过
```

清单里 6 个 app 全 PASS（Kodi / TrollAppsTV / TSLTVDemo / Umbra / irisin / 测试包），
`uninstall org.xbmc.kodi-tvos` 被正确拒绝（退出码 1，目录未动）。

---

## 1. 还差什么才算「TrollStore 那样」

| 能力 | TrollStore(iOS) | 我们现在 |
|---|---|---|
| 一条命令/一次点击安装 ipa | ✅ GUI | ✅ CLI |
| 签名与信任全自动 | ✅ | ✅ |
| 已装应用列表 + 状态 | ✅ | ✅ CLI |
| 卸载/重装 | ✅ | ✅ |
| **电视上能点**（GUI） | ✅ | ❌ |
| 从系统「文件」/ 分享面板导入 | ✅ | ❌ |
| 持久化（重启后仍在） | CoreTrust 漏洞 | 越狱 exec 钩子（已验证机制，待重启复验） |
| 装加密的 App Store 包 | ✅（解密后） | ❌ 缺解密管线 |

---

## 2. 下一层：三个可独立验收的里程碑

### M1 —— Daemon 化 ✅ 已完成（2026-11-23 05:39）

常驻 `tsltvd`（root，LaunchDaemon 托管）已上线，同一套动词走 IPC；
CLI 多了 `tsltv remote <子命令…>` 这个瘦客户端入口。

**为什么不是 unix socket**：tvOS 的 launchd 不支持按连接拉起进程。
`Sockets` + `inetdCompatibility`(或 `OnDemand`) 实测 `runs = 0`——socket 建出来了，
但连上来时 launchd 从不 spawn 子进程。改用 **FIFO + 响应文件**：

```
客户端 → /var/run/tsltv/req.fifo   "<id>\t<子命令…>"
服务端 → /var/run/tsltv/<id>.out   （执行输出）
         /var/run/tsltv/<id>.rc    （退出码）
         /var/run/tsltv/<id>.done  （完成标记）
```

**实测验收**：

| 检查 | 结果 |
|---|---|
| `remote list` / `doctor` / `verify` | 全部正常，5 个 app 全 PASS |
| `remote adopt --all` / `trust retrust` | 写操作成功，`重放完成: ok=5 bad=0` |
| 非 root 调用 | 失败（目录 0700 / FIFO 0600 拦住） |
| 非法动词 `remote evilcmd` | 被拒绝，`未知子命令`，退出码 2 |
| 含元字符 `remote "list; rm -rf /"` | 客户端直接拒绝，退出码 1 |
| daemon 日志 | `/var/log/tsltvd.log` 记录每次 exec/done |

**另一个坑**：plist 若写成直接 exec 脚本 + `KeepAlive=true`，launchd 报 `EX_CONFIG(78)`。
必须照 `com.trollstorelite.tv.retrust` 的形状：`ProgramArguments = [/bin/sh, 脚本]`、`ProcessType=Background`、
`KeepAlive=false`、并显式给 `StandardOutPath/StandardErrorPath`。

### M2 —— TV 上的 GUI 🟡 已构建并安装，界面待亮屏验收（2026-11-23 05:48）

`TrollStoreLiteTV.app`（UIKit/SwiftUI，走我们已有的自签+信任通道安装它自己）。
四个页面：已装列表 / 安装（URL 或局域网发现）/ 详情（cdhash、信任状态、重装）/ 设置。

GUI 不直接做签名，只调 `tsltv remote <子命令…>`，逻辑与 CLI 共用一份。

**已完成部分**（`gui/`，ObjC + UIKit，`gui/build.sh` 一条命令编译）：

- 主列表：bundle id / 信任✓✗ / 注册✓✗ / 来源(install|adopt) / cdhash 前 12 位
- 动作：启动、重新信任、卸载、校验全部、安装 IPA（输入直链）
- 通信：写 `/var/run/tsltv/req.fifo`，轮询 `<id>.done`，读回 `.out`
- 运行时解析 vroot 路径（roothide 会把 `/var` 重定向，候选顺序探测）

**已验收（无屏幕可做的部分）**：

| 检查 | 结果 |
|---|---|
| 编译 | 通过，`platform 3` / `minos 17.0` |
| 安装 + 注册 | `com.trollstorelite.tv.app` 已进 uicache |
| dyld 预检 | 加载 **441** 个 dylib，零 `Library not loaded` / `Symbol not found` |
| 应用内 IPC 自检（`TSLTV_SELFTEST=1`） | `probe` 返回 6 条、`verify` 全 PASS —— **GUI 自己的代码真的跑通了** |

**界面已验收（自截图）**：app 在进程内用 `CALayer renderInContext:` 把自己的窗口渲染成 PNG
写到 `/rootfs/private/var/tmp/tsltv-ui.png`（`drawViewHierarchyInRect` 在 tvOS 上返回空白，
必须走 CALayer）。实测 1920×1080，能看到标题、三个按钮、6 行应用状态。

踩到的 UI 坑：
- tvOS SDK 没有 `UINavigationBar.barStyle`、`separatorColor`、`UIBarStyleBlack` → 系统导航栏改不了配色，
  干脆不用导航栏，自己做头部（标题 + 三个 `UIButton` + `tableHeaderView`）
- 默认白底下 `cell.textLabel` 是浅色，电视上几乎看不见 → 全站深色主题

**交互已验收（自动钩子 + 日志）**：`/var/tmp/tsltv-auto` 存在时，界面在 9 秒后
自动调用自身的「校验全部」动作，daemon 日志留下 `06:06:16 exec [...] verify`。
即 **UI 动作 → daemon → CLI 整条链路真实跑通**，不是只渲染了静态列表。

**唯一仍需人做的**：遥控器焦点走向（用眼睛确认焦点框移动是否顺手）。

**关于「屏幕熄灭时 `uiopen` 空转」的解法（2026-11-23 06:00 实测有效）**：
tvOS 没有 `pmset`/`caffeinate`，但可以用 **HID 事件注入**把设备唤醒 ——
`work/minos/wake.m`（dlopen 取 `IOHIDEventSystemClientCreateWithType` 等私有符号，
签名时带 `com.apple.private.hid.client.event-dispatch`）派发一次
Consumer/Play-Pause(0x0C/0xCD) 按键后，`uiopen` 立刻恢复工作：

```
已派发 HID 事件 page=0xC usage=0xCD
uiopen --bundleid com.trollstorelite.tv.app   →  rc=0
ps: 92267  1  00:24  0:00.25  .../TrollStoreLiteTV.app/TSLTV     ← PPID=1，活着
daemon log: 05:59:47 exec [...] probe   ← GUI 自己在取数据
```

**安全权衡（需知）**：为了让 mobile 身份的 GUI 能调 root 服务，
`/var/run/tsltv` 放开为 0755、`req.fifo` 0666、响应文件 0666。
即**本机任何进程都能调用这几个动词**（都是安装/校验类，不含任意 shell）。
若不需要 GUI，把 `tsltvd` 里那两行 chmod 改回 700/600 即可恢复严格模式。

**验收**：在电视上用遥控器完成一次「输入 URL → 装上 → 出现在主屏 → 启动」全流程，
且 GUI 显示的状态与 `tsltv list` 一致。

> 这是唯一的「必须有人坐在电视前」的里程碑；我这边的 `uiopen` 在屏幕熄灭时是空转的
> （连 `com.apple.TVSettings` 都拉不起来），所以这一层我做不了验收。

### M3 —— 导入通道 ✅ 已上线 Web 商店（2026-11-23 05:57）

已实现 **`tsltvweb`**：设备上常驻的原生 HTTP 服务（tvOS 二进制，LaunchDaemon 托管），
浏览器打开 `http://<AppleTV-IP>:8787` 就是完整的商店界面——列表、拖拽上传 ipa、
卸载、校验全部。**不依赖电视屏幕**，这是目前唯一「现在就能用」的入口。

架构与 tvOS 的两个限制直接相关：

- tvOS SDK **禁用了 `fork` / `posix_spawn_file_actions_*`**，进程内起不了子进程
- 不同进程的 roothide vroot 不同，`/usr`、`/bin/sh`、`/var` 都可能指向别处

所以 web 端**只做文件 I/O**：把命令写进 `/var/run/tsltv/req.fifo`，
由 `tsltvd`（launchd 起的 shell 进程，可以自由 fork）执行后写回响应文件。

**实测（2026-11-23 05:56，从 Mac 浏览器协议操作）**：

| 操作 | 结果 |
|---|---|
| `GET /` | 200，HTML 表格列出 6 个应用 |
| `GET /api/probe` | 6 条 TSV |
| `POST /api/install?name=TSLTVWeb.ipa`（body=ipa 字节） | `签名 1 / 信任 1 / 失败 0`，装进 /Applications |
| `POST /api/uninstall?bid=com.trollstorelite.tv.web` | 卸载成功，列表回到 6 条 |
| `POST /api/verify` | 6 项全 PASS |

**仍未做**：「文件」App 共享目录（`UIFileSharingEnabled`）——需要真正的 tvOS GUI 配合，
且屏幕亮着才能验。

---

## 3. 做不到 / 不该做的（已证伪，别再花时间）

| 想法 | 结论 | 证据 |
|---|---|---|
| 移植原版 TrollStore | **不可行** | CoreTrust CVE-2023-41991 的 fastPathSign 在此内核上伪造成功但 `CS_INVALID_ALLOWED` 不置位；同一 bypass 下带正确 ent 也起不来，纯 adhoc 反而能起 → bypass 等于没给任何东西 |
| 写入只读系统卷 | **不需要** | `/rootfs` 是 EROFS（dev 49,1），但我们 `uicache -i` 已能把它注册成 `Type: System`，用户视角无差别 |
| 装 App Store 加密包 | **卡在解密** | `cryptid 1` 的包（Moonlight/Danmu）启动即 `Killed: 9`；解密需要 FairPlay 密钥，属另一条研究线 |
| 靠改 minos 跑 tvOS 18+ 的包 | **未验证** | 工具已写（`work/minos/patch_minos.py`），机制层面生效；但启动验证卡在屏幕 |
| 原版 TrollStore **Lite**（APT 包 `com.opa334.trollstorelite`） | **平台墙可绕过，但 UI 未验证** | 见下 |

### 关于 TrollStore Lite 的实测（2026-11-23 05:42）

APT 里的 `com.opa334.trollstorelite`（2.1.1-2，`iphoneos-arm64e`，来自 owngoal-dev 的 RootHide 分支）
是**纯 iOS 包**：`platform 2`、`CFBundleSupportedPlatforms=[iPhoneOS]`、`UIDeviceFamily=[1,2]`、
`minos 14.0`、`cryptid 0`、无签名。

- 用 `tsltv install` 能装上、能注册（`uicache` 收下了），签名/信任 3 个二进制全成功
- 直接执行 → **dyld 拒绝**：

  ```
  dyld: Library not loaded: /usr/lib/libobjc.A.dylib
    Reason: 'wrong platform to load into process'
  ```

  这是 dyld 的平台校验，与签名/权限无关。
- 把 `LC_BUILD_VERSION.platform` 从 2 改成 3（工具：`work/minos/patch_platform.py`）后重装：
  **dyld 报错消失，实测加载 595 个 dylib（含 UIKit）**。
- 静态比对 tvOS SDK：它引用的 67 个 ObjC 类里，tvOS 缺 4 个 ——
  `MCMAppContainer`、`PSListController`、`PSListItemsController`、`PSSpecifier`（懒绑定，跑到才崩）。
  反过来 `LSApplicationWorkspace` / `LSApplicationProxy` 在 tvOS 上**有**，所以「枚举/安装应用」这条 API 路是通的。

⇒ 结论：**iOS 包在 tvOS 上的第一道墙是可破的**（platform 补丁），
但能不能真正跑起来还要看 UI 与否（屏幕亮着才能验），
以及 TrollStore 自己的 CoreTrust 路径在 tvOS 17 上已知无效（见上表）。

---

## 4. 建议的下一步顺序

1. **M1 daemon**（纯远程可做，今晚就能推）
2. 屏幕通电 → 先把「重启后免重放」验收掉（这是唯一存疑的持久化环节）
3. **M2 GUI**（需要人在电视前）
4. **M3 局域网投放**
5. `cryptid 1` 解密：单独立项，别和上面的主线混

---

## 5. 设计约束（改代码前先看这些）

- **安全红线**：一切写入只落在数据卷/jbroot；不碰 `/rootfs`；不自动重启设备。
- **卸载护栏**：只有清单里 `origin=install` 的条目可被 `uninstall`；`adopt` 来的（越狱自带 app）
  拒绝卸载。想覆盖行为必须先显式 `adopt`。
- **ent 逐 app 生成**：`application-identifier` 必须等于自身 bundle id，否则静默拒启。
- **双哈希**：`-Hsha1 -Hsha256` 缺一不可。
- **`get-task-allow`**：只对**本工具自签**的包是硬要求；
  越狱自带 app（如 irisin）走 Relaxin 自己的签名通道，没有该键照样运行 —— `verify` 已按 `origin` 区分。
- **`uicache` 必须带路径**：`uicache -p <app>` / `-u <app>`，单用 `-s` 不会注册任何东西。
- **信任缓存里是大写哈希**：比对要 `grep -i`。
