[中文](../zh/ROADMAP.md) · English

# From "it installs and it runs" to "it feels like a product": the TrollStore Lite TV roadmap

Written 2026-11-23 05:40. What is shipped today is the **CLI layer** (`/usr/libexec/tsltv/tsltv`).
Below it is split into three parts: what exists now / what the next layer does / what simply cannot be done.

---

## 0. What exists now (verified)

One command does it all: download → unpack → self-sign every Mach-O → write the kernel trust cache → register → record.

```sh
sudo tsltv doctor                     # environment self-check
sudo tsltv install /path/App.app       # install from a local app/ipa
sudo tsltv install-url http://…/x.ipa  # install from a direct link (TrollStore's typical use)
sudo tsltv adopt --all                 # bring already-installed apps under management (no re-signing)
sudo tsltv list                        # manifest
sudo tsltv verify [bundle-id…]         # verify: trust hit / adhoc / registration / hrcfb
sudo tsltv uninstall <bundle-id>       # only apps this tool installed may be uninstalled
sudo tsltv trust retrust               # replay trust from the manifest
```

Measured (2026-11-23 05:35):

```text
==> download http://192.168.1.10:8899/TSLTVCli.ipa
100  6475  100  6475    0     0   301k      0 --:--:-- --:--:-- --:--:--
==> signed 1 / trusted 1 / failed 0
PASS  com.trollstorelite.tv.cli    cdhash=b914ffb10f3c…  origin=install hrcfb=1
all passed
```

All six apps in the manifest PASS (Kodi / TrollAppsTV / TSLTVDemo / Umbra / irisin / test bundle),
and `uninstall org.xbmc.kodi-tvos` is correctly refused (exit code 1, directory untouched).

---

## 1. What is still missing to be "like TrollStore"

| Capability | TrollStore (iOS) | What we have now |
|---|---|---|
| Install an ipa with one command / one tap | ✅ GUI | ✅ CLI |
| Fully automatic signing and trust | ✅ | ✅ |
| Installed-app list with status | ✅ | ✅ CLI |
| Uninstall / reinstall | ✅ | ✅ |
| **Tappable on the TV** (GUI) | ✅ | ❌ |
| Import from the system "Files" app / share sheet | ✅ | ❌ |
| Persistence (still there after a reboot) | CoreTrust vulnerability | jailbreak exec hook (mechanism verified, awaiting reboot re-test) |
| Install encrypted App Store bundles | ✅ (after decryption) | ❌ no decryption pipeline |

---

## 2. Next layer: three independently acceptable milestones

### M1 — Daemonize ✅ Done (2026-11-23 05:39)

A resident `tsltvd` (root, managed by launchd) is live and the same verbs go over IPC; the CLI
gained `tsltv remote <subcommand…>` as a thin-client entry point.

**Why not a unix socket**: tvOS's launchd does not support launching a process per connection.
With `Sockets` + `inetdCompatibility` (or `OnDemand`) we measured `runs = 0` — the socket is
created, but launchd never spawns a child when a client connects. So we switched to **FIFO + response files**:

```
client → /var/run/tsltv/req.fifo   "<id>\t<subcommand…>"
server → /var/run/tsltv/<id>.out   (execution output)
         /var/run/tsltv/<id>.rc    (exit code)
         /var/run/tsltv/<id>.done  (completion marker)
```

**Measured acceptance**:

| Check | Result |
|---|---|
| `remote list` / `doctor` / `verify` | All fine, all 5 apps PASS |
| `remote adopt --all` / `trust retrust` | Write operations succeed, `replay done: ok=5 bad=0` |
| Non-root invocation | Fails (blocked by directory 0700 / FIFO 0600) |
| Illegal verb `remote evilcmd` | Rejected, `unknown subcommand`, exit code 2 |
| Metacharacter payload `remote "list; rm -rf /"` | Rejected by the client itself, exit code 1 |
| daemon log | `/var/log/tsltvd.log` records every exec/done |

**Another trap**: if the plist is written as direct exec of the script + `KeepAlive=true`, launchd
reports `EX_CONFIG(78)`. It must follow the shape of `com.trollstorelite.tv.retrust`:
`ProgramArguments = [/bin/sh, script]`, `ProcessType=Background`, `KeepAlive=false`, plus explicit
`StandardOutPath`/`StandardErrorPath`.

### M2 — GUI on the TV 🟡 Built and installed, UI still awaiting an on-screen acceptance (2026-11-23 05:48)

`TrollStoreLiteTV.app` (UIKit/SwiftUI, installed through the very self-sign + trust channel we
already have). Four screens: installed list / install (URL or LAN discovery) / details (cdhash,
trust state, reinstall) / settings.

The GUI never signs anything itself; it only calls `tsltv remote <subcommand…>`, sharing one
implementation of the logic with the CLI.

**Parts completed** (`gui/`, ObjC + UIKit, one command to build: `gui/build.sh`):

- Main list: bundle id / trusted ✓✗ / registered ✓✗ / origin (install|adopt) / first 12 chars of the cdhash
- Actions: launch, re-trust, uninstall, verify all, install IPA (direct link input)
- Communication: writes to `/var/run/tsltv/req.fifo`, polls `<id>.done`, reads back `.out`
- Runtime resolution of vroot paths (roothide redirects `/var`, so we probe candidate orders)

**Accepted so far (everything doable without a screen)**:

| Check | Result |
|---|---|
| Compiles | Passes, `platform 3` / `minos 17.0` |
| Install + register | `com.trollstorelite.tv` is in uicache |
| dyld precheck | Loads **441** dylibs, zero `Library not loaded` / `Symbol not found` |
| In-app IPC self-test (`TSLTV_SELFTEST=1`) | `probe` returns 6 entries, `verify` all PASS — **the GUI's own code really runs** |

**UI accepted (self-screenshot)**: in-process, the app renders its own window to PNG with
`CALayer renderInContext:` and writes it to `/rootfs/private/var/tmp/tsltv-ui.png`
(`drawViewHierarchyInRect` returns blank on tvOS, so CALayer is mandatory). Measured 1920×1080;
the title, the three buttons and 6 rows of app status are visible.

UI traps we hit:
- The tvOS SDK has no `UINavigationBar.barStyle`, no `separatorColor`, no `UIBarStyleBlack` → the
  system navigation bar cannot be recoloured, so we dropped the nav bar entirely and built our own
  header (title + three `UIButton`s + `tableHeaderView`)
- On the default white background `cell.textLabel` is a light colour and is nearly invisible on a
  TV → the whole app uses a dark theme

**Interaction accepted (automatic hook + logs)**: when `/var/tmp/tsltv-auto` exists, the UI calls
its own "verify all" action 9 seconds after launch, and the daemon log shows
`06:06:16 exec [...] verify`. That means the whole **UI action → daemon → CLI** chain really runs;
it is not merely rendering a static list.

**The only thing still needing a human**: remote focus behaviour (eyeball whether the focus box moves comfortably).

**On the "`uiopen` is a no-op while the screen is off" problem (measured working, 2026-11-23 06:00)**:
tvOS has no `pmset`/`caffeinate`, but you can wake the device with **HID event injection** —
`work/minos/wake.m` (dlopen for private symbols such as `IOHIDEventSystemClientCreateWithType`,
signed with `com.apple.private.hid.client.event-dispatch`) dispatches a single
Consumer/Play-Pause (0x0C/0xCD) keypress, and `uiopen` immediately works again:

```
HID event dispatched: page=0xC usage=0xCD
uiopen --bundleid com.trollstorelite.tv   →  rc=0
ps: 92267  1  00:24  0:00.25  .../TrollStoreLiteTV.app/TrollStoreLiteTV     ← PPID=1, alive
daemon log: 05:59:47 exec [...] probe   ← the GUI is fetching its own data
```

**Security trade-off (be aware)**: so that the mobile-identity GUI can call the root service,
`/var/run/tsltv` is opened up to 0755, `req.fifo` to 0666 and the response files to 0666.
That means **any process on the device can call these verbs** (all of them install/verify-grade,
none is an arbitrary shell). If you do not need the GUI, change those two chmod lines in `tsltvd`
back to 700/600 to restore strict mode.

**Acceptance**: complete a full "enter URL → install → appears on the home screen → launch" flow on
the TV with the remote, and have the GUI's displayed state match `tsltv list`.

> This is the only milestone that "requires a human sitting in front of the TV"; on my side
> `uiopen` is a no-op while the screen is off (it cannot even bring up `com.apple.TVSettings`), so I
> cannot accept this layer myself.

### M3 — Import channel ✅ The web store is live (2026-11-23 05:57)

Implemented **`tsltvweb`**: a native HTTP service resident on the device (a tvOS binary managed by
a LaunchDaemon). Open `http://<AppleTV-IP>:8787` in a browser and you get the complete store UI —
list, drag-and-drop ipa upload, uninstall, verify all. **It does not depend on the TV screen**,
which makes it the only entry point that "works right now".

The architecture follows directly from two tvOS limits:

- The tvOS SDK **bans `fork` / `posix_spawn_file_actions_*`**, so no child processes can be started in-process
- Different processes see different roothide vroots, so `/usr`, `/bin/sh` and `/var` can point elsewhere

So the web side **only does file I/O**: it writes commands into `/var/run/tsltv/req.fifo`, and
`tsltvd` (a launchd-started shell process, free to fork) executes them and writes responses back to
the response files.

**Measured (2026-11-23 05:56, driven over HTTP from a Mac browser)**:

| Operation | Result |
|---|---|
| `GET /` | 200, HTML table listing 6 apps |
| `GET /api/probe` | 6 TSV records |
| `POST /api/install?name=TSLTVWeb.ipa` (body = ipa bytes) | `signed 1 / trusted 1 / failed 0`, installed into /Applications |
| `POST /api/uninstall?bid=com.trollstorelite.tv.web` | Uninstall succeeded, list back to 6 entries |
| `POST /api/verify` | All 6 PASS |

**Still missing**: the "Files" app shared directory (`UIFileSharingEnabled`) — that needs a real
tvOS GUI to cooperate, and the screen has to be on to verify.

---

## 3. What cannot be done / should not be done (disproven, stop spending time on it)

| Idea | Conclusion | Evidence |
|---|---|---|
| Port the original TrollStore | **Not viable** | CoreTrust CVE-2023-41991's fastPathSign forges successfully on this kernel but `CS_INVALID_ALLOWED` is not set; under the same bypass a build with correct entitlements still won't start, while plain adhoc does → the bypass gives you nothing |
| Write to the read-only system volume | **Not needed** | `/rootfs` is EROFS (dev 49,1), but `uicache -i` already registers into `Type: System`, which is indistinguishable from the user's point of view |
| Install encrypted App Store bundles | **Blocked on decryption** | Bundles with `cryptid 1` (Moonlight/Danmu) give `Killed: 9` at launch; decryption needs FairPlay keys, which is a separate research track |
| Run tvOS 18+ bundles by rewriting minos | **Unverified** | The tool exists (`work/minos/patch_minos.py`) and works at the mechanism level, but launch verification is blocked on the screen |
| The original TrollStore **Lite** (APT package `com.opa334.trollstorelite`) | **The platform wall is breakable, but the UI is unverified** | See below |

### Measured notes on TrollStore Lite (2026-11-23 05:42)

`com.opa334.trollstorelite` in APT (2.1.1-2, `iphoneos-arm64e`, from owngoal-dev's RootHide fork)
is a **pure iOS package**: `platform 2`, `CFBundleSupportedPlatforms=[iPhoneOS]`,
`UIDeviceFamily=[1,2]`, `minos 14.0`, `cryptid 0`, unsigned.

- `tsltv install` installs it and it registers (`uicache` accepts it); signing/trusting all 3 binaries succeeds
- Executing it directly → **dyld refuses**:

  ```
  dyld: Library not loaded: /usr/lib/libobjc.A.dylib
    Reason: 'wrong platform to load into process'
  ```

  This is dyld's platform check, unrelated to signing or permissions.
- After changing `LC_BUILD_VERSION.platform` from 2 to 3 (tool: `work/minos/patch_platform.py`) and
  reinstalling: **the dyld error is gone; measured 595 dylibs loaded (including UIKit)**.
- Statically comparing against the tvOS SDK: of the 67 ObjC classes it references, tvOS lacks 4 —
  `MCMAppContainer`, `PSListController`, `PSListItemsController`, `PSSpecifier` (lazy binding, so it
  crashes only when reached). Conversely `LSApplicationWorkspace` / `LSApplicationProxy` **do**
  exist on tvOS, so the "enumerate/install apps" API route is open.

⇒ Conclusion: **the first wall for iOS packages on tvOS is breakable** (the platform patch), but
whether it really runs also depends on the UI (only verifiable with the screen on), and
TrollStore's own CoreTrust path is known to be ineffective on tvOS 17 (see the table above).

---

## 4. Suggested next order

1. **M1 daemon** (pure remote work, could ship tonight)
2. Power the screen on → accept "no replay needed after a reboot" first (the only doubtful persistence link)
3. **M2 GUI** (needs a human in front of the TV)
4. **M3 LAN delivery**
5. `cryptid 1` decryption: a separate project, do not mix it into the main line above

---

## 5. Design constraints (read these before changing code)

- **Safety red line**: all writes land on the data volume / jbroot; never touch `/rootfs`; never reboot the device automatically.
- **Uninstall guard**: only entries with `origin=install` in the manifest can be `uninstall`ed;
  anything that came in via `adopt` (apps shipped with the jailbreak) refuses to uninstall. To
  override the behaviour you must explicitly `adopt` first.
- **Entitlements are generated per app**: `application-identifier` must equal the app's own bundle
  id, otherwise launching is silently refused.
- **Dual hash**: `-Hsha1 -Hsha256`, both are mandatory.
- **`get-task-allow`**: a hard requirement only for packages **this tool self-signs**; apps that
  ship with the jailbreak (irisin, for example) go through Relaxin's own signing channel and run
  without the key — `verify` already distinguishes by `origin`.
- **`uicache` needs a path**: `uicache -p <app>` / `-u <app>`; `-s` on its own registers nothing.
- **Hashes in the trust cache are uppercase**: compare with `grep -i`.
