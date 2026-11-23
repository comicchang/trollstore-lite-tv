# 验收证据（2026-11-23 03:26 CST）

目标：在 Apple TV 4K 3代 / tvOS 17.0 / Relaxin(roothide) 越狱上，实现 TrollStore 等效能力，
让自签名应用（以 Kodi 21.3 为测试对象）能安装并运行。

结论：**已达成**。以下为设备上直接采集的原始输出。

---

## 1. 设备与 Kodi 运行状态

```
采集时间(设备): Mon Nov 23 03:26:50 CST 2026
设备: J255AP  系统: 21J354  kernel: 23.0.0

== 1. Kodi 运行状态 ==
mobile           74466   1.5  4.4 448371888 179600   ??  Ss    3:23AM   0:05.27 /var/containers/...
```

同一 PID 连续采样，CPU 时间持续累积（说明是活着的进程，不是残留记录）：

```
PID=74466 CPU=0.6% MEM=4.4% TIME=0:04.06
PID=74466 CPU=0.9% MEM=4.4% TIME=0:04.09
PID=74466 CPU=0.9% MEM=4.4% TIME=0:04.12
```

## 2. Kodi 自身日志（最强证据：应用已完全初始化）

```
info <general>: Starting Kodi (21.3 (21.3.0) Git:20251031-a3a448d26b). Platform: tvOS ARM 64-bit
info <general>: Running on Apple Inc. AppleTV14,1 with tvOS 17.0 (Version 17.0 (Build 21J354)),
                kernel: Darwin ARM 64-bit version 23.0.0
info <general>: GUI format 3840x2160, Display HDMI: 3840x2160 @ 23.98Hz
                                               Starting v7.4.4
                                               Kodi:    v21.3 (Kodi Omega)
                                               Python:  v3.11.7
info <general>: Register - new joystick device registered: Micro Gamepad (0000:0000)
```

日志文件：`/var/mobile/Library/Caches/kodi.log`（347 行）

## 3. 信任链

```
Kodi 二进制 CDHash = 3b9be3f3571686ec71dec9829676cbbb40904ea4
在信任缓存中命中: 1
缓存总条目: 327

Relaxin trust cache 1
  Carrier: Unknown
  Layout: Single bank
  Health: healthy
  Appendable: yes
  Entries: 327 / 740
  Detail: dynamic-owner
```

Kodi 版本与平台：
```
CFBundleIdentifier = "org.xbmc.kodi-tvos"
CFBundleShortVersionString = "21.3"
CFBundleSupportedPlatforms = ( AppleTVOS )
```

## 4. 工具与自动重建

```
/usr/libexec/almatrust/
  install.sh     ← 安装器（.ipa/.app → 双哈希自签 → 写信任 → 装 /Applications → 注册）
  trustlib.sh    ← 清单 + 重放
  retrust.sh     ← 守护载荷
  manifest.txt   ← 45 条二进制
/Library/LaunchDaemons/com.alma.retrust.plist
```

重启用户态后守护进程自动执行（非手动触发）：

```
03:23:41 daemon start
03:23:48 retrust done ok=45 bad=0
03:23:49 daemon exit
```

## 5. 安装器实测输出

```
# sh /usr/libexec/almatrust/install.sh /var/tmp/AlmaHello.ipa
==> AlmaHello (com.alma.hello)
==> 签名 1 / 信任 1
==> 完成: /Applications/AlmaHello.app
    启动: uiopen --bundleid com.alma.hello
```

启动验证：进程连续 3 次采样均存活。
（同一安装器也用于 Kodi：`Kodi.app` 的 38 个二进制全部双哈希签名并写入信任缓存）

## 6. 三条关键技术结论

| 结论 | 证据 |
|---|---|
| 信任判定 = 内核 TXM 信任缓存里的 20 字节 sha256 cdhash | 缓存命中 grep=1；`Appendable: yes` |
| `/var/containers/Bundle/Application/**` 路径被 `jbclient_blacklist_check_bundle` 拒绝 | 同一二进制在 `/var/tmp` 下 add 成功、在该路径下 add 计数不变 |
| 签名必须 `ldid -S<ent> -M -Hsha1 -Hsha256`（双哈希），且 ent 必须含 `get-task-allow` | 单哈希：秒退；双哈希+该权限：Kodi 稳定运行 |

`get-task-allow` 的作用：让进程从启动起被视作可调试，内核跳过"无效代码页"校验——
这是之前所有尝试"fork 后 1~2 秒神秘退出、无任何日志"的根因。

## 6.5 "任意 IPA" 的验证样本（2026-11-23 04:48）

| 应用 | 来源 | 关键属性 | 结果 |
|---|---|---|---|
| Kodi 21.3 | 官方 tvOS deb | `cryptid 0`, `minos 12.0` | ✅ 运行 1h+ |
| TrollAppsTV 0.92-4b | GitHub release IPA | `cryptid 0`, `minos 14.0`, platform 3 | ✅ 运行 |
| AlmaHello | 自编译 | 无加密 | ✅ 运行 |
| AlmaKit | 自编译 + 自定义 framework | 无加密 | ✅ 运行（签名 2 个二进制） |
| Yattee 2.0.0-β278 | GitHub release IPA | `minos 18.0` | ✗ dyld: built for tvOS 18.0 |
| Moonlight / Danmu | App Store 拷贝 | `cryptid 1`（FairPlay） | ✗ Killed: 9 |

当时的实时状态（两个第三方应用同时在线）：

```
TrollAppsTV  PID=82858  TIME=0:00.39
Kodi         PID=82779  TIME=0:02.28
/Applications: AlmaHello  Kodi  TrollAppsTV  Umbra  irisin
```

**结论**：安装器对「未加密 + minos ≤ 17.0」的 tvOS 应用通用；App Store 加密包与高版本构建是仅有的两类硬失败。

## 7. 安全边界

- 系统卷 `/`（sealed 只读快照）零写入
- 改动仅在 jbroot：`/Applications`、`/usr/libexec/almatrust`、`/Library/LaunchDaemons`
- 未修改 Relaxin basebin、未更换证书、未改内核
- 设备未变砖，SSH/越狱全程可用；测试残留已清理

## 8. 已知限制

- 应用必须有有效签名才能进信任缓存（裸二进制需先 ldid 签名）
- Kodi 的 `AppData/AppHome/addons/*.dylib` 未纳入清单（启动后加载，本次未验证是否需要）
- 守护进程重放 45 条约 9 秒
- 整机重启后需重跑一次 Relaxin 越狱（semi-untethered 特性），之后守护进程自动恢复信任
