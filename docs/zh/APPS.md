[中文](APPS.md) · [English](../en/APPS.md)

# 应用安装指南（Demo / Kodi / 浏览器 / 油猴脚本）

本页汇总已在本项目（tvOS 17.0 + Relaxin/roothide）上实测通过的典型应用安装步骤与排障要点。

> 两种最常用的安装入口：
> - **网页商店（推荐）**：浏览器打开 `http://<AppleTV-IP>:8787`，直接把 `.ipa` 拖进页面（实时显示上传速率与安装耗时）。
> - **命令行**：`scp app.ipa mobile@<IP>:/var/tmp/ && ssh mobile@<IP> 'sudo tsltv install /var/tmp/app.ipa'`。

---

## 1. 自带 Demo 应用（`TSLTVDemo-unsigned.ipa`）

`TSLTVDemo` 是本项目自带的最小无签名 tvOS 应用（源码在 `examples/hello-tvos/`），带反色风格 tvOS 图标，适合首次装完 TrollStore Lite TV 后验证整条安装链路。

### 方式 A：直接用 Release 产物

1. 从 [GitHub Releases](https://github.com/comicchang/trollstore-lite-tv/releases) 下载 `TSLTVDemo-unsigned.ipa`。
2. 打开 `http://<AppleTV-IP>:8787`，将 `TSLTVDemo-unsigned.ipa` 拖入上传区。
3. 看到 `签名 1 / 信任 1 / 失败 0` 即安装完成，主屏会出现 **TSLTV Demo** 图标。

### 方式 B：在 macOS 上自行编译

```sh
git clone https://github.com/comicchang/trollstore-lite-tv.git
cd trollstore-lite-tv
./examples/hello-tvos/build.sh
# 产物：dist/TSLTVDemo-unsigned.ipa
```

验证与卸载：

```sh
ssh mobile@<IP> 'sudo tsltv verify com.example.tsltv.demo'
ssh mobile@<IP> 'sudo tsltv launch com.example.tsltv.demo'
ssh mobile@<IP> 'sudo tsltv uninstall com.example.tsltv.demo'
```

---

## 2. Kodi（官方 tvOS 构建）

Kodi 官方为 tvOS 提供未加密构建（实测版本 **Kodi 21.3**）。

### 获取并打包为 `.ipa`

1. 前往 [kodi.tv/download/tvos](https://kodi.tv/download/tvos) 下载官方 tvOS 的 `.deb` 包（如 `org.xbmc.kodi-tvos_21.3-0_iphoneos-arm64.deb`）。
2. 在 Mac/Linux 上将其转为标准 `.ipa`（只需 3 条命令）：

```sh
mkdir -p /tmp/kodi-ipa/extract /tmp/kodi-ipa/Payload
dpkg-deb -x org.xbmc.kodi-tvos_*.deb /tmp/kodi-ipa/extract
mv /tmp/kodi-ipa/extract/Applications/Kodi.app /tmp/kodi-ipa/Payload/
(cd /tmp/kodi-ipa && zip -qr0 Kodi-tvOS.ipa Payload)
```

> 提示：用 `-0`（无压缩）打包可以大幅缩短 Apple TV 端解压时间。

### 安装到 Apple TV

将 `Kodi-tvOS.ipa` 拖入网页商店 `http://<AppleTV-IP>:8787`（或走 `tsltv install`）。
- Kodi 包含约 12,000+ 文件与 151 个 Mach-O 动态库；v2.1.5+ 的单进程 `machoscan` + 同卷 `mv` + 4 路并发签名可在数十秒内完成全量签名与信任注入。
- v2.1.6+ 的 `tsltv trust retrust` 也会自动重放 Kodi 的全部 151 个动态库。
- 多机 SMB 媒体源映射、MariaDB 共享片库/搜索同步与未来新设备接入指南见 [KODI-SYNC.md](KODI-SYNC.md)。

### 常见排障：Kodi 启动黑屏

如果 Kodi 进程存活但电视画面黑屏，且 `/var/mobile/Library/Caches/kodi.log` 出现 `GUI format 0x0` 或大量 `LoadTTF` 报错，原因通常是旧配置里固定了一个 tvOS 未探测到的分辨率。移除以下两行后冷重启即可恢复（实测恢复为 `1920x1080 @ 60.00Hz`）：

```sh
ssh mobile@<IP> '
  GS=/var/mobile/Library/Caches/Kodi/userdata/guisettings.xml
  cp "$GS" "${GS}.bak"
  grep -vE "videoscreen\.(resolution|screenmode)" "${GS}.bak" > "$GS"
  killall -9 Kodi 2>/dev/null || true
'
```

---

## 3. tvOS 浏览器（`jvanakker/tvOSBrowser`）

Apple TV 没有内置 Safari。开源项目 [`jvanakker/tvOSBrowser`](https://github.com/jvanakker/tvOSBrowser) 基于 tvOS 私有 `WKWebView` API 提供多标签与视频全屏浏览（已在 tvOS 17.0 实测正常运行）。

在装有 Xcode 的 macOS 上无签名编译并打包：

```sh
git clone --depth 1 https://github.com/jvanakker/tvOSBrowser.git /tmp/tvOSBrowser
xcodebuild -project /tmp/tvOSBrowser/_Project/Browser.xcodeproj \
  -scheme Browser -sdk appletvos -configuration Release \
  -derivedDataPath /tmp/tvOSBrowser-build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

mkdir -p /tmp/tvOSBrowser-ipa/Payload
cp -a /tmp/tvOSBrowser-build/Build/Products/Release-appletvos/Browser.app /tmp/tvOSBrowser-ipa/Payload/
(cd /tmp/tvOSBrowser-ipa && zip -qr tvOSBrowser.ipa Payload)
```

随后把 `tvOSBrowser.ipa` 拖进 `http://<AppleTV-IP>:8787` 即可安装（主屏名 **tvOS Browser**）。

---

## 4. 内置油猴脚本托管（Web 商店 `:8787`）

自 **v2.1.6** 起，网页商店内置了一个轻量本地 Userscript 托管服务，持久化存放在 `/var/mobile/Library/tsltv-userscripts/`：

- **统一加载入口**：`http://127.0.0.1:8787/api/userscripts.js`（自动按文件名排序合并所有已启用的 `.js`，每段包在独立 `try/catch` IIFE 中，带 `Access-Control-Allow-Origin: *` 与实时拉取计数）。
- **管理方式**：直接在浏览器打开 `http://<AppleTV-IP>:8787/` 底部的「油猴脚本」区域上传、启停或删除 `.js` 文件，无需重新打包 IPA。
- **典型用途**：配合支持本地 userscript 入口的 Cobalt / 网页壳应用（例如配合独立的 `tvos-cobalt-userscript` 补丁工具加载 TizenTube 等脚本），完全本地离线秒加载，不依赖外网 CDN。

---

## 5. 加密 App Store 包说明

`tsltv` **不提供任何 FairPlay 解密能力**，遇到 `cryptid≠0` 的加密 IPA 会在安装前直接拒绝。
如需研究自己合法获取的 tvOS 应用并进行本地解密与自定义脚本注入，请参考独立的开源补丁工具项目文档（与本安装器解耦）。
