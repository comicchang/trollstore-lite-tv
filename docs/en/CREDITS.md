[中文](../zh/CREDITS.md) · English

# Dependencies and credits

This project stands on the shoulders of the work below. **None of it belongs to this repository**,
but without it none of this runs.

## Runtime prerequisites

| Project | Role | Notes |
|---|---|---|
| [**Relaxin**](https://github.com/owngoal-dev/Relaxin) (MIT, roothide-family jailbreak) | Provides the appendable kernel trust cache via `jbctl trustcache add` | The precondition for **every** capability here. No jailbreak, no path |
| [**roothide**](https://github.com/roothide) | Relaxin's bootstrap / vroot framework (`>= 0.1.0-5`) | Provides the `jbroot` layout, `/usr/libexec` redirection and LaunchDaemon patches |
| [`ldid`](https://github.com/ProcursusTeam/ldid) / [`uicache`](https://github.com/ProcursusTeam/uikittools-ng) from [**Procursus**](https://github.com/ProcursusTeam/Procursus) | Ad-hoc signing, LaunchServices registration | Installed via APT; not bundled in this repository |

> For installing and using [Relaxin](https://github.com/owngoal-dev/Relaxin), refer to its official release channels; this repository does
> not ship the jailbreak itself and takes no responsibility for jailbreak-related risk.

## Optional research & companion tools (referenced only, not bundled)

| Project | License | Role & version limits |
|---|---|---|
| [**Lakr233/vphone-cli**](https://github.com/Lakr233/vphone-cli) | MIT | Runs virtualized Apple firmware on Apple Silicon Macs via `Virtualization.framework` for low-risk research and debugging. **Current latest-version limit**: its tvOS presets only support recent builds around **tvOS 26.6–27.x** (~tvOS 27; tvOS 27+ requires a macOS 27 host) and cannot boot tvOS 17.x |

## Design borrowings

| Project | What we borrowed | License |
|---|---|---|
| [**TrollStore**](https://github.com/opa334/TrollStore) (opa334) | RootHelper's subcommand interface, the `iTunesMetadata` approach, the "register as System/User" distinction, the layering of "the app is just a shell + a privileged helper" | Mostly MIT (`Copyright (c) 2022-2026 Lars Fröder`; `RootHelper/uicache.m` is BSD-4-Clause and is not included) |
| [**TrollStore Lite**](https://github.com/opa334/TrollStore) | The LITE compile variant of the same source tree, which confirmed that the "registration type" difference is real | MIT (same as above) |
| [**TrollStore-tvOS**](https://github.com/straight-tamago/TrollStore-tvOS) (straight-tamago) | Reference for tvOS build wiring and porting architecture research | MIT + upstream notices |

This project **does not copy** source from the projects above; the interface compatibility layer
`src/fork/tsh` is an independent implementation. See [NOTICE](../../NOTICE) for details.

## Explicitly not depended on

The following capabilities **do not exist** in this project and are not planned:

- CoreTrust exploitation (CVE-2023-41991) — ineffective on tvOS 17.0, see [Design decisions](DESIGN-DECISIONS.md)
- FairPlay decryption (encrypted App Store bundles are not handled)
- Any mechanism that bypasses App Store payment

## Toolchain

Xcode / AppleTVOS SDK (building tvOS executables), `dpkg-deb` (packaging on the device), POSIX shell.
