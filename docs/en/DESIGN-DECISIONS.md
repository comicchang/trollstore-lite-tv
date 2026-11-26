[中文](../zh/DESIGN-DECISIONS.md) · English

# TrollStore Lite TV — design notes

A TrollStore equivalent on tvOS. The goal is not to reproduce opa334's implementation but to
rebuild the same capability **within what this machine can actually do** (tvOS 17.0 + a
Relaxin/roothide jailbreak + no CoreTrust): **install any unencrypted .ipa and make it really run**.

---

## 1. One principle that cannot be worked around

Whether iOS/tvOS lets a binary execute depends on **the cdhash trust cache in the kernel**, not on
the file path and not on whether an Apple signature is present. That leaves exactly three steps:

```
ldid ad-hoc dual-hash signing  →  write the binary's sha256 cdhash into the Relaxin cache  →  LaunchServices registration
```

Three hard requirements (fail any one and the process exits silently, with zero logs):

1. `ldid -S<ent> -Cadhoc -Hsha1 -Hsha256` — signing only sha1 or only sha256 dies instantly
2. Entitlements follow each bundle's original signature (upstream `TrollStore RootHelper · signApp` semantics): a bundle main executable keeps its own entitlements, and only a main app with none falls back to `TROLLTROLL.*`. `get-task-allow` / `application-identifier` are no longer force-injected
3. Container-field normalization (container required by default; without `no-container`/`no-sandbox` write `container-required=<bundle-id>`; Lite additionally writes `jb.pmap_cs.custom_trust`)

---

## 2. Components and data flow

```
   ┌───────────┐   ┌───────────┐   ┌───────────┐
   │   TV UI   │   │ web store │   │    CLI    │ three front ends
   └─────┬─────┘   └─────┬─────┘   └─────┬─────┘
         │ FIFO request  │               │ direct exec (root)
         └───────────────┴───────────────┘
                         ▼
                ┌─────────────────┐
                │      tsltvd     │  resident, root, serial
                │  (FIFO engine)  │  the only place that signs/trusts/records
                └────────┬────────┘
                         ▼
                ┌─────────────────┐
                │      tsltv      │  pure POSIX sh, no python/jq dependency
                └────────┬────────┘
                         ▼
   ldid · jbctl trustcache · tsreg · /Applications
```

State file `/usr/libexec/tsltv/installed.tsv`:
`bundle_id ⇥ path ⇥ cdhash ⇥ installed_at ⇥ origin(install|adopt)`.
**Uninstallation may only act on entries in this table** — it is the one guard against deleting system apps.

---

## 3. Why a FIFO and not a unix socket

| Attempt | Result |
|---|---|
| launchd `Sockets` + `inetdCompatibility` / `OnDemand` | The socket gets created, but on connection **`runs = 0`**; launchd never spawns |
| In-process `fork` / `posix_spawn_file_actions_*` | The tvOS SDK marks them `unavailable`; it does not even compile |
| **FIFO + response files** | ✅ Pure file I/O, usable from either side |

Protocol: the client writes `<id>\t<verb args>` to `req.fifo`; the engine executes and writes
`<id>.out` / `<id>.rc` / `<id>.done`; the client polls `.done`. Verb whitelist + shell
metacharacters rejected, no `eval`.

> The cost: about 1.5 seconds of fixed overhead per round trip, and `probe` is slower on the first
> call. So the engine caches `probe` for 5 seconds (cold 13.2s → warm 1.4s), and front-end refreshes
> no longer sit and wait.

---

## 4. The paths that "looked right but do not work"

| Idea | Measured conclusion |
|---|---|
| Port the original TrollStore | **Not viable.** The whole thing rests on CoreTrust (CVE-2023-41991) + a forged certificate; on tvOS 17.0 that bypass forges successfully but `CS_INVALID_ALLOWED` is never set. Under the same bypass, a build with correct entitlements still won't start, while plain adhoc does |
| TrollStore **Lite** | **Registration/container APIs work; the CoreTrust path does not.** Lite is the same source tree built with `-DTROLLSTORE_LITE` (MIT), and its core is still CoreTrust. However `MCMAppContainer` / `MCMAppDataContainer` and `LSApplicationWorkspace` do exist and work on tvOS 17.0 (Stage 2B); `tsreg` now uses them for native registration |
| Writing to the read-only system volume | **Not needed.** `/rootfs` is EROFS; `tsreg` registers apps as `Type: System` through `LSApplicationWorkspace` without touching the system volume |
| Installing an encrypted App Store bundle | **Impossible.** `cryptid 1` gives `Killed: 9` at launch; FairPlay decryption would be required. We now **reject before installing** and explain why |
| Validating "will it run" by direct exec | **Invalid.** A UIKit app necessarily dies outside a FrontBoard context; occasional survival is a momentary illusion |

---

### 4.1 Registration and containers (since 2026-11-26)

- Installs and updates go through `tsreg`: MCM app-data / plugin / App Group containers plus
  `LSApplicationWorkspace` registration as System, carrying Entitlements, the plugin table and the
  containerization fields. Uninstalls go through `tsreg unregister` (App Group containers are
  reference-counted).
- `tsreg` is a clean-room implementation (runtime `dlopen` + `NSClassFromString`, no
  `-undefined dynamic_lookup`) and does not copy the upstream BSD-4-Clause `uicache.m`, so the
  repository stays pure MIT.
- System-app detection only trusts the sealed volume (`/rootfs/Applications`,
  `/System/Applications`, including `<jbroot>/rootfs/Applications`) and `installed.tsv`.
  Under RootHide, self-installed apps under `/Applications` are never treated as system apps.
- `refresh` / `mods` use `tsreg` only for new installs carrying the `.tsltv-tsreg` marker; apps
  installed by the old `uicache` path keep their original registration, containers and data.

---

## 5. Delivery shape

```
dist/trollstore-lite-tv_1.0.4_appletvos-arm64e.deb   33K
├── /usr/libexec/tsltv/{tsltv,tsltvd,tsltvweb,trustlib.sh,retrust.sh}
├── /Library/LaunchDaemons/com.trollstorelite.tv.{daemon,web,retrust}.plist
└── /Applications/TrollStoreLiteTV.app
```

`postinst` does four things (none optional, because **dpkg overwriting files drops signatures**):
re-sign the web service and the app → inject into the trust cache → register with `uicache -p` →
bootstrap the three daemons. `prerm` does the reverse: stop the daemons, unregister the app, and
leave other apps alone.

---

## 6. Acceptance matrix (2026-11-23)

| Item | Evidence |
|---|---|
| Install a self-compiled tvOS app | `PASS` after cdhash injection, `uiopen` brings it up under launchd (PPID=1) |
| Install third-party IPAs | TrollAppsTV (GitHub release) + Kodi 21.3 both running |
| Reject an encrypted bundle | Artificially built `cryptid=1` bundle → `install rejected`, exit code 1, nothing written |
| Uninstall guard | `uninstall org.xbmc.kodi-tvos` → refused, exit code 1, directory untouched |
| Whole chain | All seven steps of `dist/accept.sh` PASS (see `dist/ACCEPTANCE.txt`) |
| Self-update | Triggered from the web → downloaded 33,088 bytes → dpkg → daemons restarted, response uninterrupted |

---

## 7. Still unverified / boundaries

- **No replay needed after a full reboot**: mechanically an exec hook tops up trust automatically
  (measured: cdhash hits 0→1), but a real "reboot + re-run Relaxin" is needed to confirm it, and a
  human has to be in front of the TV.
- **Remote focus feel**: HID injection cannot drive the tvOS focus engine; a human has to press the buttons.
- **App icons**: all six apps' icons are inside `Assets.car`, and there is no unpacking tool on the device.
- **Encrypted bundles**: would need a FairPlay decryption pipeline — a separate research track.
