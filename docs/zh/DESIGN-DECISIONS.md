[中文](DESIGN-DECISIONS.md) · [English](../en/DESIGN-DECISIONS.md)

# TSLTV 设计说明

tvOS 上的 TrollStore 等价物。目标不是复刻 opa334 的实现，而是在**这台机器能做到的范围内**
（tvOS 17.0 + Relaxin/roothide 越狱 + 无 CoreTrust）重建同样的能力：
**装任意未加密的 .ipa 并让它真正跑起来**。

---

## 1. 一条不可绕过的原理

iOS/tvOS 决定一个二进制能不能执行，看的是**内核里那份 cdhash 信任缓存**，不是文件路径，也不是
有没有 Apple 签名。所以整套方案只剩三步：

```
ldid 做 ad-hoc 双哈希签名  →  把该二进制的 sha256 cdhash 写进 Relaxin 缓存  →  LaunchServices 注册
```

三个必要条件（任何一条不满足就静默退出、零日志）：

1. `ldid -S<ent> -Cadhoc -Hsha1 -Hsha256` —— 只签 sha1 或只签 sha256 会秒死
2. entitlements 沿用各 bundle 原签名（上游 `TrollStore RootHelper · signApp` 语义）：bundle 主可执行保留自身 entitlements，主 app 完全没有时才回落 `TROLLTROLL.*`；不再强制注入 `get-task-allow` / `application-identifier`
3. 容器字段归一（缺省需要容器且无 `no-container`/`no-sandbox` → `container-required=<bundle-id>`；Lite 额外写 `jb.pmap_cs.custom_trust`）

---

## 2. 组件与数据流

```
   ┌──────────┐   ┌──────────┐   ┌──────────┐
   │ 电视 UI  │   │ 网页商店 │   │   CLI    │      三个前端
   └────┬─────┘   └────┬─────┘   └────┬─────┘
        │  FIFO 请求    │              │ 直接 exec（root）
        └──────┬───────┴──────────────┘
               ▼
      ┌─────────────────┐
      │   tsltvd    │  常驻、root、串行处理
      │  （FIFO 引擎）   │  唯一做签名/信任/记账的地方
      └────────┬────────┘
               ▼
      ┌─────────────────┐
      │    tsltv    │  纯 POSIX sh，无 python/jq 依赖
      └────────┬────────┘
               ▼
   ldid · jbctl trustcache · uicache · /Applications
```

状态文件 `/usr/libexec/tsltv/installed.tsv`：
`bundle_id ⇥ path ⇥ cdhash ⇥ 安装时间 ⇥ origin(install|adopt)`。
**卸载只允许作用于这张表里的条目** —— 这是防止误删系统应用的唯一护栏。

---

## 3. 为什么是 FIFO，不是 unix socket

| 尝试 | 结果 |
|---|---|
| launchd `Sockets` + `inetdCompatibility` / `OnDemand` | socket 建得出来，但连接到来时 **`runs = 0`**，launchd 从不 spawn |
| 进程内 `fork` / `posix_spawn_file_actions_*` | tvOS SDK 直接标 `unavailable`，编都编不过 |
| **FIFO + 响应文件** | ✅ 纯文件 I/O，任何一方都能用 |

协议：客户端写 `<id>\t<动词 参数>` 到 `req.fifo`；引擎执行后写 `<id>.out` / `<id>.rc` /
`<id>.done`；客户端轮询 `.done`。动词白名单 + 拒绝 shell 元字符，不做 `eval`。

> 代价：单次往返固定开销约 1.5 秒，`probe` 首次更慢。因此在引擎侧给 `probe` 加了 5 秒缓存
> （冷 13.2s → 热 1.4s），前端刷新不再干等。

---

## 4. 那些"看起来该这样、实际不行"的路

| 想法 | 实测结论 |
|---|---|
| 移植原版 TrollStore | **不可行**。它整套建立在 CoreTrust（CVE-2023-41991）+ 伪造证书上；该 bypass 在 tvOS 17.0 上伪造成功但 `CS_INVALID_ALLOWED` 永不置位，同 bypass 下带正确 ent 也起不来，纯 adhoc 反而能起 |
| TrollStore **Lite** | **同样不可行**。它是同一套源码加 `-DTROLLSTORE_LITE` 编译（MIT 许可），只改"默认注册为 User/System"和隐藏设置；核心仍是 CoreTrust，且依赖 tvOS 上不存在的 `MCMAppContainer`。全仓库对信任缓存的引用为 0 |
| 写入只读系统卷 | **不需要**。`/rootfs` 是 EROFS，但 `uicache` 已能把 app 注册成 `Type: System`，用户视角无差别 |
| 装加密的 App Store 包 | **做不到**。`cryptid 1` 启动即 `Killed: 9`，需要 FairPlay 解密。现在改为**装前就拒绝**并说明原因 |
| 靠"直接 exec"验证能否运行 | **无效**。UIKit app 脱离 FrontBoard 上下文必死，偶发存活是瞬时假象 |

---

## 5. 交付形态

```
dist/trollstore-lite-tv_1.0.4_appletvos-arm64e.deb   33K
├── /usr/libexec/tsltv/{tsltv,tsltvd,tsltvweb,trustlib.sh,retrust.sh}
├── /Library/LaunchDaemons/com.trollstorelite.tv.{tsltvd,tsltvweb,retrust}.plist
└── /Applications/TrollStoreLiteTV.app
```

`postinst` 承担四件事（缺一不可，因为 **dpkg 覆盖文件会丢签名**）：
补签 web 与 app → 注入信任缓存 → `uicache -p` 注册 → bootstrap 三个守护进程。
`prerm` 反过来：停守护进程、注销应用，不碰其他 app。

---

## 6. 验收矩阵（2026-11-23）

| 项 | 证据 |
|---|---|
| 安装自编译 tvOS app | cdhash 注入后 `PASS`，`uiopen` 由 launchd 拉起（PPID=1） |
| 安装第三方 IPA | TrollAppsTV（GitHub 发布）+ Kodi 21.3 均在跑 |
| 加密包拒绝 | 人造 `cryptid=1` 包 → `拒绝安装`，退出码 1，未写盘 |
| 卸载护栏 | `uninstall org.xbmc.kodi-tvos` → 拒绝，退出码 1，目录未动 |
| 整链路 | `dist/accept.sh` 七步全 PASS（见 `dist/ACCEPTANCE.txt`） |
| 自更新 | 网页触发 → 下载 33,088 字节 → dpkg → 守护进程重启，响应不中断 |

---

## 7. 仍未验证 / 边界

- **整机重启后的免重放**：机制上由 exec 钩子自动补信任（实测 cdhash 命中 0→1），但需要
  一次真实的"重启 + 重跑 Relaxin"才能确认，必须有人在电视前。
- **遥控器焦点手感**：HID 注入驱动不了 tvOS 焦点引擎，只能人按。
- **应用图标**：六个 app 的图标都在 `Assets.car` 里，设备上没有解包工具。
- **加密包**：需要 FairPlay 解密管线，属另一条研究线。
