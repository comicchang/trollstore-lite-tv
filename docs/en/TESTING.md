[中文](../zh/TESTING.md) · English

# Testing

There are two layers: **environment and trust-chain self-checks** (`scripts/verify.sh`, nine items)
and **install-loop acceptance** (`scripts/accept.sh`, seven steps). Both are read-only or
rollback-safe and will not damage the device state.

## How to run

```sh
./tests/run.sh                                             # no device needed (CI runs this too)
ATV_PASS='<device sudo password>' ./scripts/verify.sh 192.168.1.23     # nine items, needs a device
ATV_PASS='<device sudo password>' ./scripts/accept.sh 192.168.1.23     # seven steps, needs a device
```

## tests/run.sh — the part that needs no device

| Group | Coverage |
|---|---|
| Script syntax | `sh -n` over every `.sh`, the CLI and the daemon |
| plists | `plutil -lint` (LaunchDaemons, Info.plist) |
| CLI usage | `version` output format, missing arguments, exit codes for unknown subcommands |
| Injection blocking | `remote` rejecting `;`, `|` and backticks |
| Pre-install verdicts | `precheck_verdict` on four inputs: allow / reject encrypted / warn iOS / warn minOS |
| Mach-O parsing | Compiles a tvOS binary on the spot and asserts `platform=3 minos=17.0 cryptid=0` |
| demo ipa | After building, checks `Payload/TSLTVDemo.app` layout, `Assets.car` icon, `CFBundleExecutable` match and that it really is unsigned |
| Uninstall origin | CLI `uninstall` refuses `origin=adopt` and still removes `origin=install` |
| Exit-code passthrough | `tsh` passes 171 / 179 / 180 / 181 / 184 through unchanged |
| tsreg build | tvOS cross-compile + Mach-O metadata (platform=3 / minos=17.0 / cryptid=0) |
| Mod injection | `modinject` writes an `LC_LOAD_DYLIB` (ncmds +1); `machoscan` recognises Mach-O precisely and maps the prefix |
| Stage 1 gate | `tests/stage1/run.sh`: cross-compiles the minimal CLI and UIKit tvOS units and validates arm64 / platform=3 / minOS 17.0 / cryptid=0 / Info.plist / entitlements (zero device contact) |

Current macOS + tvOS SDK run: **all 46 assertions pass**. Linux CI skips SDK-dependent checks.

## CI (.github/workflows/ci.yml)

| Job | Runner | Content | Blocking |
|---|---|---|---|
| `lint` | ubuntu | shellcheck (warnings fail the job), executable bits, CRLF | yes |
| `test` | ubuntu | `tests/run.sh` (SDK-dependent items skip themselves) | yes |
| `macOS full` (separate workflow, manual trigger) | macos-14 | Full test suite (including Mach-O parsing and the demo ipa) + packaging | — |

> The macOS runner needs macOS minutes available on the account, otherwise the job stays
> `cancelled` — and that marks the whole run as cancelled too (the badge turns red). So the default
> CI only runs on Linux, and the SDK-dependent jobs live in `.github/workflows/macos.yml`, triggered
> manually. The local equivalent: `./tests/run.sh && ./scripts/build-deb-local.sh`.
> **Releases** do not use CI's macOS runner; they use one local command: `./scripts/publish-release.sh`.

## verify.sh — environment and trust chain

| # | Check | Criterion |
|---|---|---|
| 1 | jbroot exists | `/var/containers/Bundle/Application/.jbroot-*` |
| 2 | Trust cache queryable | `jbctl trustcache info` hits a Relaxin cache |
| 3 | App installed | The target app's main executable exists |
| 4 | Ad-hoc self-signed | `ldid -h` reports `flags=0x2(adhoc)` |
| 5 | No Apple certificate | `TeamIdentifier=not set` |
| 6 | cdhash in the cache | At least 1 hit |
| 7 | Process alive | Visible in `ps` |
| 8 | **Started by launchd** | `PPID=1` (rules out "hand-exec'd" false evidence) |
| 9 | Installer in place | `/usr/libexec/tsltv/tsltv` |

## accept.sh — the install loop

1. Install/upgrade the deb, wait for the service to be ready (poll for at most 20s)
2. Compile a minimal tvOS app on the spot and package it into an ipa
3. `tsltv install` it (asserting the precheck output, the sign/trust counts and the cdhash)
4. `tsltv verify` passes
5. Launch with `uiopen`, assert `PPID=1`
6. `tsltv uninstall` it
7. Clean up temporary files

Any failing step prints the state on the spot and exits non-zero.

## Historical results

| Date | Version | verify.sh | accept.sh | Notes |
|---|---|---|---|---|
| 2026-11-23 09:15 | 1.0.8 | 9/9 PASS | 7/7 PASS | First complete loop, including the `PPID=1` assertion |
| 2026-11-23 22:42 | 2.0.3 | 9/9 PASS | 7/7 PASS | Cold-boot install verification after the rename refactor |
| 2026-11-23 23:35 | 2.0.5 | 9/9 PASS | 7/7 PASS | Regression run after moving web upload to streaming |

### Web upload stress test (2.0.5)

| Metric | Before the fix | After the fix |
|---|---|---|
| Process memory during a 200MB upload | Climbed to roughly the bundle size and got killed by jetsam (`JETSAM_REASON_MEMORY_PERPROCESSLIMIT`) | **8.5MB → 8.9MB, constant** |
| Process restarts | Never came back after dying (`KeepAlive=false`) | `runs = 1` (no restart at all) |
| After `kill -9` | Did not come back | `runs = 2`, a new PID takes over and the web store returns 200 again |

Long-run stability evidence (same device, no reboot):

```
uptime 122 days          (the device's own last reboot predates the jailbreak)
TrollStoreLiteTV.app  12h20m    TV UI running continuously
tsltvd/tsltvweb 12h21m    engine and web service running continuously
Kodi           17h32m    third-party app running continuously
```

## Boundary tests (done; conclusions in docs/en/DESIGN-DECISIONS.md)

| Scenario | Result |
|---|---|
| Encrypted bundle (artificially built with `cryptid=1`) | Rejected before install, exit code 1, nothing written to disk |
| iOS bundle (`platform=2`) | Installs, but dyld refuses to load system libraries (`wrong platform to load into process`) |
| Uninstalling a system app / an app this tool did not install | Guard refuses, exit code 1, directory untouched |
| `uiopen` while the TV is asleep | No-op (returns 0 without launching anything, not even a system app) |
| Self-update (dpkg triggered from the web) | Works, and the HTTP response is not cut short by the service restarting itself (the work is deferred to the background) |

## Not yet verified

- **Full reboot → re-run jailbreak → apps just work**: mechanically `com.trollstorelite.tv.retrust`
  replays automatically (manual run measured `replay done: ok=6 bad=0`), but the complete chain
  needs a reboot with a human present.
- **Remote focus behaviour**: HID injection cannot drive the tvOS focus engine; only a human can confirm.
- **Bundles built against tvOS 18+**: the `tools/patch_minos` idea can lower minOS, but this is unverified.
