[中文](PORTING-TROLLSTORE.md) · [English](../en/PORTING-TROLLSTORE.md)

# 把 TSLTV 的机制移植进 TrollStore（Lite）—— 实测记录

目标：让 TrollStore 的安装路径不再依赖 CoreTrust，而是走「ad-hoc 签名 + 内核信任缓存」。
下面是**实际试过**的结论，不是推测。

---

## 1. 上游的结构（读源码得到）

```
TrollStore.app  ──spawnRoot()──▶  RootHelper （root 二进制）
                                   ├ install [force] [custom|installd] <ipa>
                                   ├ uninstall <bundle-id>
                                   ├ refresh / refresh-all
                                   ├ modify-registration <path> System|User
                                   └ enable-jit / url-scheme / reboot / …
```

关键点：**app 里没有安装逻辑**，`-[TSApplicationsManager installIpa:]` 只是拼参数调
`spawnRoot(rootHelperPath(), args)`。真正干活的全在 `RootHelper/main.m` 的 `installApp()`：

1. 解包（libarchive）
2. `ldid` 签名 + **CoreTrust 假证书绕过（fastPathSign）**
3. 用 `MCMAppContainer` 建容器，拷到 `/var/containers/Bundle/Application/<UUID>/`
4. 写 `.TrollStorePersistenceHelper`
5. `uicache -p` 注册（`registerPath()`）

---

## 2. 为什么它在这台机器上编不过 / 跑不了

| 依赖 | 在 tvOS 17.0 上的实际情况 |
|---|---|
| `posix_spawn` / `posix_spawn_file_actions_*` | SDK 标 `unavailable`，编译直接报错（RootHelper 的 `spawnRoot()`、`killall()` 全废） |
| `posix_spawnattr_set_persona_*` | 同上 |
| `MCMAppContainer` / `MCMAppDataContainer` | 公开 Xcode `AppleTVOS.sdk` 头文件未暴露；实测 tvOS 17.0 运行时存在（见 [FULL-TROLLSTORE-GAP.md](FULL-TROLLSTORE-GAP.md) §5.2） |
| `PSListController` / `PSSpecifier` | 不存在，设置界面整块用不了 |
| **CoreTrust（CVE-2023-41991）** | `TrollStore Lite TV` 不依赖此路径（早期关于 tvOS 17.0 失效的初步推断已在 [FULL-TROLLSTORE-GAP.md](FULL-TROLLSTORE-GAP.md) §2 中更正为待复核） |

所以「把上游 fork 过来加个 tvOS target」这条路是死的，不是没试。

---

## 3. 实际可行的移植方式：换掉最底层，保留接口

既然 tvOS 上**不能 fork/exec**，特权操作只能由一个 launchd 托管的 **shell 进程**完成
（这是我们趟出来的唯一可行形状）。于是移植的最小改动是：

**把 `RootHelper` 换成一个实现了同样子命令的 shell 脚本。**

本目录的 `tsh` 就是那个脚本，接口与上游一一对应：

```sh
tsh install [force] [custom|installd] <ipa|tipa|app>
tsh uninstall <bundle-id>
tsh refresh            # 重新注册已装应用（uicache -p）
tsh refresh-all        # uicache -a
tsh registration <bid> # 查看 System/User
tsh trust-retrust      # 按清单重放信任缓存
```

对 TrollStore 源码的改动只有一处（示意）：

```diff
--- a/TrollStore/TSApplicationsManager.m
+++ b/TrollStore/TSApplicationsManager.m
@@
-    int ret = spawnRoot(rootHelperPath(), args, nil, logOut);
+    // tvOS: 不能 exec，改为把请求交给常驻引擎（FIFO），由 launchd 托管的
+    //       tsltvd 执行；成功后同样刷新应用列表
+    int ret = tsltvRequest(args);   // 写入 /var/run/tsltv/req.fifo
```

`tsltvRequest()` 用纯文件 I/O 实现（写 FIFO → 轮询 `.done` → 读 `.out`），
不需要任何被禁 API。GUI 侧我们就是这样做的，见 `../gui/main.m` 的 `ATRun()`。

---

## 4. 实测：接口层已跑通

用 TrollStore 的**原始调用形式**驱动我们的实现（设备上执行）：

```
$ tsh install custom /var/tmp/ForkTest.ipa
[tsh] TrollStore 兼容安装 (args: custom)
    元数据: Fork Test App v1.2.3          ← 读 iTunesMetadata.plist
    探测: platform=3 minos=17.0 cryptid=0 ← 装前检查（加密包直接拒）
==> com.trollstorelite.tv.forktest
==> 签名 1 / 信任 1 / 失败 0
    cdhash: 69071878bcbd3c6c8f0679768615c7ed022c0a71

$ tsh registration com.trollstorelite.tv.forktest
Name: ForkTest / Bundle Identifier: com.trollstorelite.tv.forktest / …

$ tsh uninstall com.trollstorelite.tv.forktest
==> 完成
```

也就是说：**底层机制已经可以替换过去**，剩下的只是 UI 层的事——
而 UI 层在 tvOS 上本来就要重写（私有框架缺失），我们已经重写为 `TrollStoreLiteTV.app`。

---

## 5. 结论

- ✅ **机制可移植**：`tsh` 已用上游的调用约定跑通安装/卸载/注册查询
- ✅ **可信缓存的逻辑值得加**：上游靠 CoreTrust，我们靠 `jbctl trustcache add`，
  实测这是 tvOS 上唯一走得通的路；开机重放由 LaunchDaemon 承担
- ❌ **整包 fork 不可行**：`posix_spawn` 被禁 + `MCMAppContainer` 缺失 + CoreTrust 失效
- ⚠️ **UI 不能照搬**：`PSListController`/`PSSpecifier` 在 tvOS 上不存在，
  上游的设置页、部分列表控件都用不了
