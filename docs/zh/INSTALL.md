[中文](INSTALL.md) · [English](../en/INSTALL.md)

# 安装与使用

面向：想在已越狱 Apple TV 上装第三方 tvOS 应用的人。

---

## 0. 前置条件

| 项 | 要求 |
|---|---|
| 设备 | Apple TV HD / 4K（本项目的实测机是 **Apple TV 4K 3代 A15**，`AppleTV14,1`） |
| 系统 | **tvOS 17.x**（实测 17.0 / 21J354） |
| 越狱 | **Relaxin**（roothide 系越狱）已生效，`roothide >= 0.1.0-5` |
| 访问 | 能 SSH 登录到设备（默认 `mobile` 用户），并且有 sudo 权限 |
| 主机 | macOS（打包用）或任意能 `scp`/`ssh` 的机器 |

确认越狱是否生效：

```sh
ssh mobile@<device-ip> 'ls -d /var/containers/Bundle/Application/.jbroot-* && jbctl trustcache info | head -4'
```

看到 `.jbroot-<HASH>` 目录和 `Jailbreak trust caches / Status: complete` 才算就绪。
本工具所有脚本都会**自动探测**这个 `.jbroot-*` 目录名，不需要你手填哈希。

---

## 1. 安装 TrollStore Lite TV

### 方式 A：Mac 一条命令（推荐）

```sh
git clone https://github.com/comicchang/trollstore-lite-tv.git
cd trollstore-lite-tv
ATV_PASS='<设备sudo密码>' ./scripts/install.sh 192.168.1.23
```

它会：上传 deb → `dpkg -i` → 等待守护进程起来 → 打印三个入口和自检结果。

### 方式 B：手动 dpkg

```sh
scp dist/trollstore-lite-tv_<ver>_appletvos-arm64e.deb mobile@192.168.1.23:/var/tmp/
ssh mobile@192.168.1.23 'sudo dpkg -i /var/tmp/trollstore-lite-tv_<ver>_appletvos-arm64e.deb'
```

> `/var/tmp` 有 sticky 位，若同名文件已存在且属于 root，`scp` 会 `Permission denied`。
> 换个文件名即可。

### 安装过程中发生了什么

`postinst` 会做四件**缺一不可**的事（原因见 [ARCHITECTURE](ARCHITECTURE.md)）：

1. 给 `tsltvweb` / `wake` / `modinject` / `TrollStoreLiteTV.app` 主可执行等 **Mach-O 文件重新签名**。`tsh` 是 shell 脚本，不交给 ldid。
2. 把这些 Mach-O 与 App 的 cdhash 写入**内核信任缓存**
3. `uicache -p` 注册电视应用，建立 `/usr/bin/{tsltv,trollstore-lite,tsl}` 别名
4. 启动三个 LaunchDaemon：`tsltvd`（引擎）、`tsltvweb`（网页）、`com.trollstorelite.tv.retrust`（开机重放信任）

### 验证

```sh
ssh mobile@192.168.1.23 'sudo tsltv doctor'     # 环境自检
ssh mobile@192.168.1.23 'sudo tsltv verify'     # 每个应用的信任/注册/签名状态
curl -sI http://192.168.1.23:8787/ | head -1        # 网页商店是否在线
```

或者用仓库里的验收脚本（会造一个临时 app，装/验/启/卸全跑一遍）：

```sh
ATV_PASS='<sudo密码>' ./scripts/accept.sh 192.168.1.23
```

期望输出：

```
PASS  守护进程在跑（等待 0s）
PASS  安装成功：cdhash: 2271d0f4…
PASS  校验通过
PASS  已由 launchd 启动：PID 12345 PPID 1
PASS  卸载干净
全部通过 ✅
```

---

## 2. 装第一个应用

### 命令行

```sh
# 本地 ipa
ssh mobile@192.168.1.23 'sudo tsltv install /var/tmp/kodi.ipa'

# 直接给链接（设备自己下载）
ssh mobile@192.168.1.23 'sudo tsltv install-url https://example.com/kodi.ipa'
```

安装前会先做**预检**，你会看到：

```
    元数据: Kodi v21.3                 ← 来自 ipa 里的 iTunesMetadata.plist
    探测: platform=3 minos=17.0 cryptid=0
==> 签名 3 / 信任 3 / 失败 0
    cdhash: 3b9be3f3571686ec71dec9829676cbbb40904ea4
```

- `cryptid=1` → 直接拒绝（加密包在 tvOS 上启动必被内核杀）
- `platform=2` → 警告"这是 iOS 包"
- `minos>17.0` → 警告"系统版本过高"

### 网页（最省事）

打开 `http://<device-ip>:8787`，把 `.ipa` 拖进页面即可。页面同时显示每个应用的
信任/注册状态、版本号，并提供「校验全部」「更新自身」按钮。

### 电视界面

主屏上的 **TSLTV**：列表显示已装应用；右上角四个按钮：

| 按钮 | 用途 |
|---|---|
| 安装 IPA | 输入直链安装（遥控器打 URL 略痛苦） |
| **装目录** | 安装「投递目录」里的所有 ipa —— 推荐配合 `scp` 使用 |
| 校验全部 | 逐项校验并弹窗报告 |
| 刷新 | 重新拉取列表 |

**投递目录**用法的原因：在电视上用遥控器输入 URL 很痛苦，所以：

```sh
scp myapp.ipa mobile@192.168.1.23:/var/tmp/tsltv-inbox/
```

然后在电视上点一下「装目录」，它会全部装完并清空目录。

---

## 3. 日常操作速查

```sh
sudo tsltv list                  # 已装清单（含 cdhash、来源）
sudo tsltv verify [bundle-id]    # 校验信任/注册/签名/entitlement
sudo tsltv uninstall <id>        # 卸载（只允许卸自己装过的）
sudo tsltv refresh               # 重新注册（图标丢失/不显示时用）
sudo tsltv refresh --all         # 全量重建注册
sudo tsltv registration          # 每个应用注册成 System 还是 User
sudo tsltv version               # 工具版本
```

别名：`trollstore-lite-tv` / `tsl` 等价于 `tsltv`。

TrollStore 风格调用（给熟悉上游的人）：

```sh
tsh install custom /var/tmp/x.ipa
tsh uninstall com.example.app
tsh refresh-all
```

---

## 4. 重启之后

信任缓存是**越狱注入**的，整机重启后：

1. 需要重新运行 **Relaxin** 越狱
2. 越狱生效后，`com.trollstorelite.tv.retrust` 会把清单里所有应用重新注入信任缓存（`installed.tsv` 为唯一来源）
3. 应用**不需要重装**

> 这一步的自动化已经验证过（手动重放：`重放完成: ok=6 bad=0`），
> 但"整机重启 → 重跑越狱 → 直接启动应用"的完整链路仍待一次真人在场的验收，
> 见 [ROADMAP](ROADMAP.md)。

---

## 5. 卸载

```sh
sudo dpkg -r trollstore-lite-tv
```

`prerm` 会停掉三个守护进程、注销电视应用、删除 `/usr/bin` 里的别名。
**不会**删除你装的其它应用（它们在 `/Applications` 里，且不在 dpkg 的清单内）。
卸载还会保留 `/var/tmp/tsltv-inbox` 中尚未安装的 IPA。

---

## 6. 排障

| 现象 | 原因 / 处理 |
|---|---|
| `uiopen` 没反应、应用起不来 | 电视处于休眠/无显示输出。用 `sudo /usr/libexec/tsltv/wake` 注入一次 HID 按键唤醒，再试 |
| 装完点开立刻闪退，无日志 | 大概率是加密包或 minOS 过高。跑 `sudo tsltv verify <id>` 与预检输出确认 |
| `scp` 报 `Permission denied` 到 `/var/tmp` | sticky 位 + 同名文件属于 root。换文件名 |
| 主屏找不到图标 | `sudo tsltv refresh`；仍不行 `sudo tsltv refresh --all` |
| 网页打不开 | `ps ax \| grep tsltvweb`；`launchctl print system/com.trollstorelite.tv.web` 看退出码 |
| `dpkg -i` 报架构不匹配 | 确认包是 `appletvos-arm64e`；必要时 `dpkg --add-architecture appletvos-arm64` |
| 装完 web 服务不启动 | 通常是签名被覆盖，`postinst` 没跑完。手动 `dpkg -i --force-confmiss` 重跑或看 `/var/log/tsltvweb.log` |

调试日志：

```
/var/log/tsltvd.log       引擎收到的每条请求与退出码
/var/log/tsltvweb.log     网页服务
/var/log/tsltv.daemon.log 开机重放信任
```
