# 贡献指南

## 开发环境

- macOS + Xcode（提供 AppleTVOS SDK）
- 一台已越狱的 Apple TV（tvOS 17.x + Relaxin），能 SSH
- `ssh` / `scp` 可用；建议配置 SSH key

```sh
# 编译三端
sh src/web/build.sh && sh src/gui/build.sh && sh src/tools/build.sh

# 打包并安装到设备
ATV_PASS='<设备sudo密码>' VER=2.0.4 ./scripts/build-deb.sh 192.168.1.23
ATV_PASS='<设备sudo密码>' ./scripts/install.sh 192.168.1.23

# 验收（装/验/启/卸 七步）
ATV_PASS='<设备sudo密码>' ./scripts/accept.sh 192.168.1.23
```

## 改动原则

1. **不许把设备搞砖**：任何改动都不得写入 `/rootfs`、不得修改 basebin、不得自动重启设备。
2. **安全优先**：新增引擎动词必须加入白名单，且参数要过元字符检查。
3. **单一事实来源**：应用状态只写 `installed.tsv`；不要再引入第二份清单。
4. **小步可验证**：每个 PR 应能让 `scripts/verify.sh` 与 `scripts/accept.sh` 通过。
5. **诚实文档**：能力边界、未验证项要写清楚，不要夸大（例如"能装任意 ipa"必须附加密包/minOS 限制）。

## 提交前自检

```sh
./tests/run.sh                           # 不需要设备：36 条断言 + shellcheck 干净
ATV_PASS=... ./scripts/verify.sh <ip>    # 九项环境与信任链检查
ATV_PASS=... ./scripts/accept.sh <ip>    # 七步安装闭环
```

## 代码风格

- shell：POSIX `sh`，不依赖 bash 特性；变量小写，函数名动词开头
- ObjC：`-fobjc-arc`；尽量不用被 tvOS 标记 `unavailable` 的 API（见 docs/ARCHITECTURE.md）
- 注释解释**为什么**，不解释"这行在做什么"
