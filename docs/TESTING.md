# 测试

分两层：**环境与信任链自检**（`scripts/verify.sh`，九项）与**安装闭环验收**
（`scripts/accept.sh`，七步）。两者都是只读/可回滚的，不会破坏设备状态。

## 怎么跑

```sh
./tests/run.sh                                             # 不需要设备（CI 也跑这套）
ATV_PASS='<设备sudo密码>' ./scripts/verify.sh 192.168.1.23     # 九项，需要设备
ATV_PASS='<设备sudo密码>' ./scripts/accept.sh 192.168.1.23     # 七步，需要设备
```

## tests/run.sh —— 不需要设备的那部分

| 组 | 覆盖 |
|---|---|
| 脚本语法 | 所有 `.sh` / CLI / 守护进程的 `sh -n` |
| plist | `plutil -lint`（LaunchDaemons、Info.plist） |
| CLI 用法 | `version` 输出格式、缺参数、未知子命令的退出码 |
| 注入拦截 | `remote` 对 `;` `|` 反引号的拒绝 |
| 安装前判定 | `precheck_verdict` 四种输入：放行 / 加密拒绝 / iOS 警告 / minOS 警告 |
| Mach-O 解析 | 现场编一个 tvOS 二进制，断言 `platform=3 minos=17.0 cryptid=0` |
| demo ipa | 构建后检查 `Payload/TSLTVDemo.app` 结构与"确实未签名" |

当前：**36 条断言全过**。CI 里同样跑这一套。

## CI（.github/workflows/ci.yml）

| Job | 运行环境 | 内容 | 是否阻塞 |
|---|---|---|---|
| `lint` | ubuntu | shellcheck（warning 即失败）、可执行位、CRLF | 是 |
| `test` | ubuntu | `tests/run.sh`（SDK 相关项自动跳过） | 是 |
| `macOS full`（独立工作流，手动/tag 触发） | macos-14 | 完整测试（含 Mach-O 解析、demo ipa）+ 打包 | — |

> macOS runner 需要账号有可用的 macOS 分钟，否则 job 会一直 `cancelled`——而且会把
> 整个 run 标成 cancelled（徽章变红）。所以默认 CI 只跑 Linux，需要 SDK 的作业放在
> `.github/workflows/macos.yml`，手动或打 tag 时触发。本地等价命令：
> `./tests/run.sh && ./scripts/build-deb-local.sh`。
> **发布**不用 CI 的 macOS runner，走本地一条命令：`./scripts/publish-release.sh`。

## verify.sh —— 环境与信任链

| # | 检查 | 判据 |
|---|---|---|
| 1 | jbroot 存在 | `/var/containers/Bundle/Application/.jbroot-*` |
| 2 | 信任缓存可查 | `jbctl trustcache info` 命中 Relaxin 缓存 |
| 3 | 应用已安装 | 目标 app 的主可执行存在 |
| 4 | ad-hoc 自签 | `ldid -h` 显示 `flags=0x2(adhoc)` |
| 5 | 无 Apple 证书 | `TeamIdentifier=not set` |
| 6 | cdhash 在缓存中 | 命中数 ≥ 1 |
| 7 | 进程存活 | 能在 `ps` 里看到 |
| 8 | **由 launchd 启动** | `PPID=1`（排除"手动 exec 的假证据"） |
| 9 | 安装器在位 | `/usr/libexec/tsltv/tsltv` |

## accept.sh —— 安装闭环

1. 安装/升级 deb，等服务就绪（轮询最多 20s）
2. 现场编译一个最小 tvOS app 并打包成 ipa
3. `tsltv install` 安装（断言预检输出、签名/信任计数、cdhash）
4. `tsltv verify` 校验通过
5. `uiopen` 启动，断言 `PPID=1`
6. `tsltv uninstall` 卸载
7. 清理临时文件

任何一步失败立即打印现场并退出非零。

## 历史结果

| 时间 | 版本 | verify.sh | accept.sh | 说明 |
|---|---|---|---|---|
| 2026-11-23 09:15 | 1.0.8 | 9/9 PASS | 7/7 PASS | 首次完整闭环，含 `PPID=1` 断言 |
| 2026-11-23 22:42 | 2.0.3 | 9/9 PASS | 7/7 PASS | 改名重构后的冷启动安装验证 |

长期稳定性证据（同一台设备，未重启）：

```
uptime 122 天            （设备自身上次重启于越狱之前）
TSLTV.app  12h20m    电视界面连续运行
tsltvd/tsltvweb 12h21m   引擎与网页服务连续运行
Kodi           17h32m    第三方应用连续运行
```

## 边界测试（已做，结论见 docs/DESIGN-DECISIONS.md）

| 场景 | 结果 |
|---|---|
| 加密包（人为构造 `cryptid=1`） | 安装前拒绝，退出码 1，不写盘 |
| iOS 包（`platform=2`） | 可安装但 dyld 拒绝加载系统库（`wrong platform to load into process`） |
| 卸载系统应用 / 非自装应用 | 护栏拒绝，退出码 1，目录未动 |
| 电视休眠时 `uiopen` | 空转（返回 0 但不启动任何 app，连系统 app 也不起） |
| 自更新（网页触发 dpkg） | 成功，且 HTTP 响应未被自身重启打断（后台延迟执行） |

## 尚未验证

- **整机重启 → 重跑越狱 → 应用直接可用**：机制上由 `com.alma.tsltv.retrust` 自动重放
  （手动执行实测 `重放完成: ok=6 bad=0`），但完整链路需要一次真人在场的重启。
- **遥控器焦点走向**：HID 注入无法驱动 tvOS 焦点引擎，只能人工确认。
- **tvOS 18+ 构建的包**：可用 `tools/patch_minos` 思路改小 minOS，但未验证。
