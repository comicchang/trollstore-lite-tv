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

## 完整流程

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

## 与"油猴子脚本"的差别

油猴子脚本是运行在页面里的 JS，改动的是网页行为；这里的 mod 是**注入进程的
原生代码**，能力更大、风险也更大。如果目标应用内部有 WKWebView，理论上也可以
做"注入 JS"的 mod，但那需要单独写一个负责 evaluateJavaScript 的 dylib，
不属于本工具的默认能力。

## 现状

- ✅ `tools/inject_dylib.py` 可用（已用 demo app 验证：`ncmds 24→25`，命令结构正确）
- ❌ 还没有 mod 仓库 / 一键安装（下一步：`mods/<name>/manifest.json` + `tsltv mods apply`）
