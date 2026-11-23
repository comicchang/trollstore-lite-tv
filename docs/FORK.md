# TSLTV · fork 层

这个目录回答一个问题：**我们这套东西和 TrollStore 是什么关系？**

一句话：**接口向 TrollStore 对齐，内核换成 tvOS 能用的那套。**
不是代码 fork（上游在 tvOS 上编不过），是**概念 fork + 接口兼容**。

```
fork/
├── NOTICE      上游版权与借鉴范围（TrollStore MIT / uicache BSD-4）
├── PORTING.md  为什么不能整包 fork，以及怎么换底层（含实测输出）
└── tsh         TrollStore RootHelper 的 tvOS 等价实现（POSIX shell）
```

## 上游 vs 我们

| 能力 | TrollStore (iOS) | TSLTV (tvOS) |
|---|---|---|
| 装 ipa | `RootHelper install …` | `tsltv install …` / `tsh install …` |
| 卸载 | `RootHelper uninstall` | `tsltv uninstall` |
| 重新注册 | `refresh` / `refresh-all` | `tsltv refresh [--all]` |
| 注册类型 | `modify-registration`（可写） | `tsltv registration`（只读，tvOS 只允许 System 语义） |
| 让二进制可执行 | **CoreTrust 假证书** | **ad-hoc 签名 + 内核信任缓存** |
| 装进容器 | `MCMAppContainer` | 直接放 jbroot `/Applications` |
| UI | UIKit + 私有 Preferences | 自写 UIKit（无私有框架依赖）+ 网页端 |
| 前端进程模型 | app → spawnRoot(helper) | 前端 → FIFO → 常驻引擎（tvOS 禁 exec） |

## 用 tsh 验证过什么

设备上以 TrollStore 的**原始调用形式**执行，看到的是完整链路：

```
tsh install custom /var/tmp/ForkTest.ipa
  → 元数据: Fork Test App v1.2.3
  → 探测: platform=3 minos=17.0 cryptid=0
  → 签名 1 / 信任 1 / 失败 0
  → cdhash: 69071878bcbd…

tsh registration com.alma.forktest  → Name/Bundle/Path
tsh uninstall com.alma.forktest     → 完成
```

细节见 `PORTING.md`。
