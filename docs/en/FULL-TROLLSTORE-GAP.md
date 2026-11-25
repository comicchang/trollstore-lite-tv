[中文](../zh/FULL-TROLLSTORE-GAP.md) · [English](FULL-TROLLSTORE-GAP.md)

# Current Baseline & Gap Analysis: Toward Full (Jailed/Persistent) TrollStore on tvOS

> Written 2026-11-25. Summarizes the current two-repository ecosystem and lays out the exact technical gaps, corrected assumptions, risk gates, and execution roadmap to move from **TrollStore Lite TV** (jailbroken kernel trustcache) to a **full persistent TrollStore for tvOS 17.0** (works after reboot without re-running the jailbreak).

---

## 1. Current Baseline (As-Is)

As of 2026-11-25, both public repositories are published with green GitHub Actions CI:

| Repository | Version / License | Capabilities | Verified Evidence |
|---|---|---|---|
| [**trollstore-lite-tv**](https://github.com/comicchang/trollstore-lite-tv) | **v2.1.6** · MIT | Jailbroken tvOS 17.x installer (TV UI + `:8787` web store + CLI `tsltv`): single-process `machoscan`, 4-way parallel signing, full-bundle `retrust`, device-side `mods apply`, GPU IOKit entitlements, built-in `:8787` local userscript host | 45/45 unit tests PASS; 4K live screenshots on Apple TV 4K (`AppleTV14,1`, tvOS 17.0 + Relaxin) confirming **Kodi 21.3 / YouTube TVL / tvOS Browser / TrollStore Lite TV** all launch and render cleanly; `tsltv verify` 7/7 PASS; `retrust` 161/161 Mach-Os PASS |
| [**tvos-cobalt-userscript**](https://github.com/comicchang/tvos-cobalt-userscript) | **v0.1.0** · MIT | Clean-room Cobalt tvOS userscript patcher: enforces `cryptid == 0`, declarative JSON profile, offline-first local hot-reload (`127.0.0.1:8787/api/userscripts.js`) + CSP whitelist, side-by-side bundle ID rewriting, local macOS icon inversion | 10/10 unit tests PASS; 4K live screenshot confirmed `TizenTube Settings` overlay and incrementing local pull counter on `:8787` |

**The one structural limitation today**:
- `TrollStore Lite TV` relies on Relaxin's jailbreak **kernel trust cache (`jbctl trustcache add`)**.
- After a full Apple TV reboot, the trust cache clears and Relaxin must be re-run (after which `com.trollstorelite.tv.retrust` automatically replays all 161 Mach-Os).
- Installed apps cannot launch while in an unjailbroken (stock/jailed) state.

---

## 2. Key Corrections (From Inspecting `straight-tamago/TrollStore-tvOS`)

Inspecting [`straight-tamago/TrollStore-tvOS`](https://github.com/straight-tamago/TrollStore-tvOS) (`RootHelper/Makefile`, `Shared/TSUtil.m`, `entitlements.plist`) surfaced two important corrections to earlier project notes ([PORTING-TROLLSTORE.md](PORTING-TROLLSTORE.md), [DESIGN-DECISIONS.md](DESIGN-DECISIONS.md)):

1. **Corrected: `posix_spawn` and `MCMAppContainer` exist at runtime on tvOS**
   - Stock Xcode `AppleTVOS.sdk` marks `posix_spawn*` as `API_UNAVAILABLE(tvos)` in public headers and omits private framework headers (`MobileContainerManager`, etc.).
   - Using a Theos patched tvOS SDK (`appletv:clang:16.4:14.0`) or `extern`/`dlsym` declarations while linking `MobileContainerManager`, `FrontBoardServices`, `RunningBoardServices`, `BackBoardServices`, and `SpringBoardServices` allows both `posix_spawnattr_set_persona_uid_np` and `MCMAppContainer` to compile and run on tvOS.
2. **Needs rigorous re-verification: CoreTrust 2 (CVE-2023-41991) on `AppleTV14,1` tvOS 17.0**
   - Earlier notes recorded that `CS_INVALID_ALLOWED` was not set on tvOS 17.0, yet `straight-tamago/TrollStore-tvOS` (v2.1) explicitly lists `tvOS 17.0` support (Apple patched CVE-2023-41991 in 17.0.1).
   - Earlier failures can easily be false negatives caused by: (a) incomplete CMS multi-signer structure instead of full `ChOma` `fastPathSign`, (b) `User` instead of `System` registration rejected by FrontBoard `libmis`, or (c) interference from jailbroken AMFI hooks.
   - **Conclusion**: Run a strict Gate 1 minimal test before committing to full engineering.

---

## 3. Gap Matrix (TrollStore Lite TV vs Full Persistent TrollStore for tvOS)

| # | Dimension | Current (`TrollStore Lite TV v2.1.6`) | Target (Full Jailed TrollStore for tvOS) | Gap & Complexity |
|---|---|---|---|---|
| **G1** | **Code trust mechanism** | `ldid` ad-hoc dual-hash + `jbctl trustcache add` (requires jailbreak) | **CoreTrust 2 (CVE-2023-41991)** multi-signer CMS bypass (`ChOma` + `fastPathSign`), tvOS ≤ 17.0 only | **Primary Gap (High)**: must prove `AppleTV14,1` tvOS 17.0 unjailbroken kernel accepts it |
| **G2** | **Privileged engine (`RootHelper`)** | Shell `tsltv` + `tsltvd` (depends on Procursus `ldid`/`uicache`/`unzip` and `$JB`) | **Self-contained native arm64 `RootHelper`** embedding `ChOma` + `fastPathSign` + `libarchive` + `OpenSSL` + `LSApplicationWorkspace`, CoreTrust-signed | **Engineering Gap (Med-High)**: zero jailbreak tools exist after a jailed reboot |
| **G3** | **Root invocation from UI** | FIFO (`/var/run/tsltv/req.fifo`) served by LaunchDaemon `tsltvd` | App holds `com.apple.private.persona-mgmt` and calls `posix_spawn` + `posix_spawnattr_set_persona_uid_np(0)` | **Engineering Gap (Medium)**: requires patched SDK / `dlsym` |
| **G4** | **App container & registration** | `$JB/Applications/*.app` + Procursus `uicache -p` | Native `/var/containers/Bundle/Application/<UUID>` via `MCMAppContainer` + `LSApplicationWorkspace` `System` registration | **Engineering Gap (Medium)**: must be verified in jailed state without roothide vroot |
| **G5** | **Persistence Helper** | Not needed (Relaxin + `retrust` restores trust) | Icon cache reloads revert CoreTrust apps to `User` (unlaunchable); requires installing a Persistence Helper into a tvOS system app to re-register as `System` while jailed | **High-Risk Gap (High)**: `AppleTV14,1` has no USB restore port and 17.0 cannot be downgraded |
| **G6** | **Initial bootstrap** | `dpkg -i` via Relaxin | Normally needs an install exploit; **already solved for us because Relaxin can bootstrap it once, then it persists jailed** | **Ready (Zero Gap)** |
| **G7** | **Frontend & ecosystem** | Mature TV UI + 39 ms web store `:8787` + live upload progress + userscript host | **Directly reusable** via a dual-backend engine abstraction (CoreTrust `spawnRoot` vs jailbreak FIFO) | **Ready (Reuse advantage)** |
| **G8** | **GPU / app entitlements** | Proven `com.apple.security.iokit-user-client-class` (AGX/IOAccel/IOSurface) + `chmod -R a+rX` | Preserve/inject required GPU entitlements during `fastPathSign` | **Ready (Proven)** |

---

## 4. Risk-Gated Roadmap (Validate Before Touching System Apps)

Because `AppleTV14,1` tvOS 17.0 is irreplaceable firmware with no USB port, proceed strictly through three gates:

### Gate 1: CoreTrust 2 Go / No-Go Proof (Zero Brick Risk)

1. **Offline kernel/KEXT static check**:
   - Inspect `CoreTrust` / `AMFI` inside the official `AppleTV14,1` tvOS 17.0 IPSW kernelcache to confirm CVE-2023-41991 is unpatched in that exact build.
2. **macOS VM rehearsal ([`Lakr233/vphone-cli`](https://github.com/Lakr233/vphone-cli))**:
   - Rehearse `ChOma` + `fastPathSign`, `posix_spawn` + persona root escalation, and `MCMAppContainer` + `LSApplicationWorkspace` registration inside an Apple Silicon VM before running on physical hardware.
3. **Minimal on-device PoC (no system app modified)**:
   - Sign a minimal `HelloCT` binary/app with `fastPathSign` and **never add it to `jbctl trustcache`**.
   - Verify it executes without any trustcache entry and launches under `Type: System`; then verify once after a clean jailed reboot (without running Relaxin).

> **Stop-loss rule**: If Gate 1 proves `AppleTV14,1` tvOS 17.0 rejects CoreTrust 2 binaries in jailed state, stop immediately and keep focusing on `TrollStore Lite TV`.

### Gate 2: Self-Contained tvOS `RootHelper` + Dual-Backend Frontend

- Set up Theos + patched tvOS SDK with `libarchive`, `libcrypto`, `ChOma`, and `fastPathSign`.
- Build self-contained `trollstorehelper-tv` (`install` / `uninstall` / `refresh` / `refresh-all` / `enable-jit`) preserving GPU IOKit entitlements.
- Reuse `TrollStoreLiteTV.app` and the `:8787` web store behind a dual-backend dispatcher:
  - **Persistent CoreTrust mode** (tvOS 17.0 jailed);
  - **Jailbreak TrustCache mode** (tvOS 17.0.1+ / Relaxin fallback).

### Gate 3: Safe tvOS Persistence Helper Verification

- Identify a harmless, re-downloadable system/built-in tvOS app as Persistence Helper host, back up its original binary, and verify full icon-cache-reload recovery while jailed.

---

## 5. Licensing & Compliance Boundaries

- Upstream `opa334/TrollStore` and `straight-tamago/TrollStore-tvOS` are mostly MIT, with BSD-4-Clause components (`RootHelper/uicache.m`) and dependencies including `OpenSSL` (Apache-2.0), `libarchive` (BSD-2-Clause), and `ChOma` (MIT). Preserve all copyright & license notices if reusing code, or keep a clean-room boundary.
- External tools referenced only in docs (never bundled): [`owngoal-dev/Relaxin`](https://github.com/owngoal-dev/Relaxin) (MIT), [`Lakr233/vphone-cli`](https://github.com/Lakr233/vphone-cli) (MIT), [`majd/ipatool`](https://github.com/majd/ipatool) (MIT), [`EthanArbuckle/fairplay-decrypt`](https://github.com/EthanArbuckle/fairplay-decrypt) (GPL-3.0).
- Never commit IPSWs, kernelcaches, `.p12` certificates, third-party `.ipa` files, or FairPlay credentials.
