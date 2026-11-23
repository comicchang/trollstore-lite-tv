# 发布流程

## 仓库首次创建

```sh
# 1) 本地初始化
cd trollstore-lite-tv
git init && git add -A && git commit -m "feat: initial public release (v2.0.3)"

# 2) 用 GitHub CLI 创建公开仓库（推荐）
brew install gh       # 若未安装
gh auth login         # 交互登录一次
gh repo create trollstore-lite-tv --public --source=. --remote=origin --push \
  --description "TrollStore Lite TV - install and run unsigned tvOS apps on jailbroken Apple TV"

# 或者不用 gh：在网页上新建空仓库后
#   git remote add origin git@github.com:<you>/trollstore-lite-tv.git
#   git push -u origin main
```

### 建议设置的仓库信息（决定别人能不能搜到你）

**Description**

> Unofficial TrollStore-Lite-style installer for jailbroken tvOS (Apple TV). Ad-hoc signing +
> kernel trust cache, no Apple certificate, no CoreTrust. TV UI + web store + CLI.

**Topics**（GitHub 仓库右上 About ⚙️ → Topics，最多 20 个）

```
trollstore  trollstore-lite  tvos  appletv  apple-tv  jailbreak  sideload
ipa  ldid  trustcache  roothide  relaxin  kodi  installer  objective-c
```

> 搜索匹配主要看 **仓库名 + description + topics**。名字里已经有 "trollstore" 和 "tv"，
> 再配上这些 topics，"trollstore apple tv" / "tvos trollstore" 这类查询就能命中。

## 没有设备时如何出包

```sh
brew install dpkg            # macOS；Linux 用 apt install dpkg
./scripts/build-deb-local.sh # → dist/trollstore-lite-tv_<ver>_appletvos-arm64e.deb
```

CI 的 `package` job 用的就是这条路径（`--root-owner-group` 保证包内属主是 root:root）。

## 发布新版本

```sh
# 有设备：直接在设备上打包并上传
ATV_IP=192.168.1.23 ATV_PASS='<设备sudo密码>' ./scripts/publish-release.sh v2.0.4

# 没设备：本地出包，再手工上传
./scripts/build-deb-local.sh && ./examples/hello-tvos/build.sh
gh release create v2.0.4 dist/*.deb dist/TSLTVDemo-unsigned.ipa --generate-notes
```

它会：

1. 在设备上重新打 `.deb`（`dist/trollstore-lite-tv_<ver>_appletvos-arm64e.deb`）
2. 构建无签名 demo ipa（`dist/TSLTVDemo-unsigned.ipa`）
3. 创建 GitHub Release 并上传这两个产物

## Release 里应该有什么

| 产物 | 说明 |
|---|---|
| `trollstore-lite-tv_<ver>_appletvos-arm64e.deb` | 安装包。`sudo dpkg -i` 即可，`postinst` 自动签名/信任/注册/起服务 |
| `TSLTVDemo-unsigned.ipa` | 无签名 demo 应用，用来验证安装链路；也是写自己 tvOS app 的模板 |

两个产物都**不含**任何 Apple 签名材料，签名在设备安装时现场完成。

## 版本号约定

- 主版本（2.x）：改名、目录结构、包名等破坏性变化
- 次版本（x.1）：新增能力（新动词、新前端）
- 修订（x.x.1）：修复与文档
