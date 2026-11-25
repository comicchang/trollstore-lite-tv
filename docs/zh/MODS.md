[中文](MODS.md) · [English](../en/MODS.md)

# Mods（原生 dylib 注入）

类比油猴子（Tampermonkey）：用户装一段外部代码，改变应用行为。
区别在于 **tvOS 上没有可注入的 JS 运行时**——这里的 "mod" 是原生 dylib，
装进 app 的 `Frameworks/` 并让主程序加载它。机制与 TrollFools 相同。

## 它做什么

```
<App>.app/
  YouTubeUnstable          ← 主程序，多一条 LC_LOAD_DYLIB
  Frameworks/libxxx.dylib  ← mod 本体（arm64 tvOS，需签名）
```

`tools/inject_dylib.py` 就地往 Mach-O 的 load commands 区插入
`LC_LOAD_DYLIB @executable_path/Frameworks/libxxx.dylib`：

```sh
python3 tools/inject_dylib.py \
  /Applications/Foo.app/Foo \
  @executable_path/Frameworks/libmod.dylib
```

它只做一件事：**改加载命令**。签名会因此失效，必须重新签名（安装器会做）。

## 用 CLI 一步装 mod（设备上直接操作）

```sh
# 目标应用已在记账里（tsltv list 能看到）
tsltv mods list                              # 看哪些应用已经带了 dylib
tsltv mods apply com.google.ios.youtube.tvl /var/tmp/libmod.dylib
```

`mods apply` 做四件事：复制 dylib 到 `Frameworks/` → 调 `modinject` 插
`LC_LOAD_DYLIB` → 重签主程序与 dylib → 重新注入信任缓存并刷新注册。

> 卸载 mod：**重装该应用**。本工具不实现 LC 删除（改回去比重装更危险）。

## 完整流程（离线手工做）

```sh
# 1. 编译 mod（必须是 tvOS arm64）
xcrun --sdk appletvos clang -target arm64-apple-tvos17.0 -dynamiclib \
      -framework Foundation mod.m -o libmod.dylib

# 2. 放进 app 的 Frameworks/
cp libmod.dylib Foo.app/Frameworks/

# 3. 注入
python3 tools/inject_dylib.py Foo.app/Foo @executable_path/Frameworks/libmod.dylib

# 4. 打包成 ipa，用 tsltv 安装（安装器会签名 + 注入信任 + 注册）
zip -qr Foo-modded.ipa Payload
tsltv install Foo-modded.ipa
```

## 限制（务必先读）

| 限制 | 说明 |
|---|---|
| 平台必须匹配 | dylib 要和主程序同为 `platform=3`（tvOS）、arm64 |
| 签名 | 注入后主程序签名失效；`tsltv install` 会重签主程序与 dylib |
| 头后空隙 | 插入依赖 load commands 之后的空隙，通常有几百字节；不够会明确报错 |
| DRM 应用无效 | 解密后的 App Store 应用仍需要 FairPlay 密钥，mod 解决不了 |
| 稳定性 | mod 崩了等于应用崩了；没有沙箱隔离 |

## 与"油猴子脚本"的差别与 Cobalt 注入路径

油猴子脚本是运行在页面里的 JS，改动的是网页行为；这里的 mod 是**注入进程的
原生代码**，能力更大、风险也更大。

针对 YouTube TV（`YouTubeUnstable`）这类网页壳应用，**实测它并非 `WKWebView`**
（二进制中不含 `WKWebView`/`UIWebView`），而是 Google 的 **Cobalt + Starboard + V8**
自研 HTML5 引擎（加载 `https://www.youtube.com/tv`）。因此：

- 传统的 ObjC `WKWebView` swizzle 对 YouTube TV 无效；
- 正确的「类油猴插件」注入路径是在 Cobalt C++ 层拦截脚本执行与 CSP 策略（如
  `HTMLScriptElement::Execute` 与 `DirectiveList::AddDirective`），放行脚本域名并向
  `youtube.com/tv` 页面注入 userscript（例如 `Exaphis/mutube` + `TizenTube Cobalt`
  即可在 YouTube 4.54.01 上实现去广告、SponsorBlock 与 4K 修复，再用 `tsltv` 永久安装免 7 天重签）。

## 现状

- ✅ CLI 已包含 `tsltv mods list` / `tsltv mods apply`（2.1.3 起），2.1.6 通过 `/rootfs/var/tmp` 桥接 + 原子替换彻底修复了设备端 `EPERM` 问题并补齐主程序完整 entitlements（真机实测通过）。
- ✅ 网页商店 `:8787` 在 2.1.6 起内置「油猴脚本管理」（`/api/userscripts.js`），可本地托管 TizenTube 与自定义 `.js` 供 YouTube TV（Cobalt）免重打包热加载。

### 已知油猴布局问题与排查方案（YouTube TVL + TizenTube）

在 YouTube TV（Cobalt 4.54.01）开启 TizenTube 默认的「视频播放器 UI 修补（`enablePatchingVideoPlayer`）」时，点开视频后、`/youtubei/v1/next` 返回前的 1–3 秒窗口内，进度条下方可能短暂出现**按钮数量跳变、图标与下方文字错位不匹配**，几秒后才稳定。

- **根因**：TizenTube 的 `TransportControls` 拦截函数（`_r()`）在 `/next` 尚未就绪时存在三处缺陷：
  1. 右侧按钮查找 `TRANSPORT_CONTROLS_BUTTON_TYPE_PLAYBACK_SETTINGS` 未命中（`idx === -1`）时直接执行原地 `splice(-1, 0, PIP)`，把迷你播放器插进错误下标并原地污染数组；
  2. 互动按钮列在 `engagementActions` 为空时无条件原地 `push` 播放速度按钮，且未守卫 `Previous`/`Next` 按钮的就绪态，导致 `/next` 返回并过滤 SuperThanks/Shopping/AI Ask 前后按钮数量反复增减，触发 Incremental DOM 节点/标签错位复用；
  3. 每次实例化 `TransportControls` 都重跑无缓存的完整 JS AST 解析，拖慢控件栏稳定。
- **规避与根治**：
  - **临时规避**：在 TizenTube 设置 → 视频播放器中关闭「视频播放器 UI 修补」（不影响去广告与 SponsorBlock）；
  - **热修根治**：对 `:8787` 托管脚本中的 `_r()` 改用浅拷贝 `.slice()`、仅在 `PLAYBACK_SETTINGS` 已就绪（`idx >= 0`）与 `engagementActions.length > 0` 时注入按钮，并缓存 AST 解析出的属性槽位，经 `/api/userscripts/save` 热更新后重启 YouTube TVL 生效。
