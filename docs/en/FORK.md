[中文](../zh/FORK.md) · English

# TrollStore Lite TV · the fork layer

This directory answers one question: **what is the relationship between our thing and TrollStore?**

In one sentence: **the interface is aligned with TrollStore; the core is swapped for the one tvOS can use.**
It is not a code fork (upstream does not compile on tvOS), it is a **conceptual fork plus interface compatibility**.

```
fork/
├── NOTICE      upstream copyright and what we borrowed (TrollStore MIT / uicache BSD-4)
├── PORTING.md  why a whole-package fork is impossible, and how the bottom layer is replaced (with measured output)
└── tsh         a tvOS equivalent of TrollStore's RootHelper (POSIX shell)
```

## Upstream vs us

| Capability | TrollStore (iOS) | TSLTV (short for TrollStore Lite TV) |
|---|---|---|
| Install an ipa | `RootHelper install …` | `tsltv install …` / `tsh install …` |
| Uninstall | `RootHelper uninstall` | `tsltv uninstall` |
| Re-register | `refresh` / `refresh-all` | `tsltv refresh [--all]` |
| Registration type | `modify-registration` (writable) | `tsltv registration` (read-only; tvOS only allows System semantics) |
| Make a binary executable | **CoreTrust fake certificate** | **ad-hoc signing + kernel trust cache** |
| Install into a container | `MCMAppContainer` | Straight into jbroot `/Applications` |
| UI | UIKit + private Preferences | Hand-written UIKit (no private framework dependencies) + a web front end |
| Front-end process model | app → spawnRoot(helper) | front end → FIFO → resident engine (tvOS bans exec) |

## What has been verified with tsh

Run on the device using TrollStore's **original invocation form**, the complete chain shows up:

```
tsh install custom /var/tmp/ForkTest.ipa
  → metadata: Fork Test App v1.2.3
  → probe: platform=3 minos=17.0 cryptid=0
  → signed 1 / trusted 1 / failed 0
  → cdhash: 69071878bcbd…

tsh registration com.trollstorelite.tv.forktest  → Name/Bundle/Path
tsh uninstall com.trollstorelite.tv.forktest     → done
```

Details in `PORTING.md`.
