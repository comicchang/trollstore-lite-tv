[中文](../zh/ARCHITECTURE.md) · English

# Architecture

## 1. One principle

Whether tvOS lets a binary execute depends on **the cdhash in the kernel trust cache** (a 20-byte
sha256), not on the file path and not on whether an Apple signature is present. The jailbreak
(Relaxin/roothide) provides an appendable trust cache: put the cdhash in and the system will
execute the binary exactly as it does a legitimate app.

So the whole approach is three things:

```
ldid -S<ent> -Cadhoc -Hsha1 -Hsha256   →   jbctl trustcache add <macho>   →   tsreg register <app>
```

### Three hard requirements (miss one and the process exits silently, with zero logs)

| Requirement | Explanation |
|---|---|
| **Dual-hash signature** | Signing only sha1 or only sha256 makes the process die instantly, with no log whatsoever |
| **Entitlements follow the original signature** | Same as upstream `opa334/TrollStore` RootHelper `signApp`: each bundle's main executable keeps its own entitlements; only a main app with none at all falls back to `TROLLTROLL.*`. `get-task-allow` / `application-identifier` are no longer force-injected |
| **Container-field normalization** | Container is required by default; without `no-container` / `no-sandbox` the tool writes `container-required=<bundle-id>` (string). A custom container id string is preserved as-is |
| **Lite trust level** | TrollStore Lite additionally writes `jb.pmap_cs.custom_trust=PMAP_CS_APP_STORE` (PMAP_CS devices then run ad-hoc binaries at App Store trust level) |
| **GPU IOKit entitlements** (OpenGL ES / Metal apps) | `com.apple.security.iokit-user-client-class` is already present in App Store / decrypted bundles' entitlements and is preserved; only the fallback `TROLLTROLL.*` set (source has no entitlements at all) lacks it |

> Runtime criteria: cdhash in the kernel trust cache + ad-hoc signature + registered.
> `tsltv verify` no longer treats `get-task-allow` as a hard gate (upstream likewise preserves each
> app's original entitlements).

---

## 2. Components

```
┌─────────────────────┐   ┌──────────────┐   ┌──────────────┐
│ TrollStoreLiteTV.app │   │   tsltvweb   │   │    tsltv     │   three front ends
│       (UIKit)        │   │   (:8787)    │   │  (POSIX sh)  │
└──────────┬──────────┘   └───────┬──────┘   └───────┬──────┘
           │   FIFO request       │                  │
           │                      │                  │ direct exec (root)
           ▼                      ▼                  │
          ┌───────────────────────────────┐          │
          │             tsltvd            │◀─────────┘   optional: `tsltv remote`
          │     root, launchd, serial     │
          └───────────────┬───────────────┘
                          ▼
   ldid · jbctl trustcache · tsreg (MCM containers + LaunchServices) · /Applications · installed.tsv
```

| Component | Language | Responsibility |
|---|---|---|
| `src/tools/tsreg.m` | ObjC | Native registration: MCM app-data / plugin / App Group containers + `LSApplicationWorkspace` register/unregister + Info.plist patches |
| `src/cli/tsltv` | POSIX sh | All business logic: unpack, precheck, sign, trust, register, record |
| `src/daemon/tsltvd` | POSIX sh | Resident engine: take commands from the FIFO, execute, write results back |
| `src/web/main.m` | ObjC | Web store (HTTP server + built-in pages) |
| `src/gui/main.m` | ObjC/UIKit | TV UI |
| `src/fork/tsh` | POSIX sh | TrollStore `RootHelper` interface compatibility layer |
| `src/tools/wake.m` | ObjC | HID key injection (wakes a sleeping TV) |
| `src/daemon/retrust.sh` | POSIX sh | Replays trust from the manifest at boot |

**State file** `/usr/libexec/tsltv/installed.tsv` (the single source of truth):

```
bundle_id ⇥ app_path ⇥ cdhash ⇥ installed_at ⇥ origin(install|adopt)
```

Uninstallation is only allowed for entries in this table — that is the one and only guard against
deleting system apps or other apps.

---

## 3. Why a FIFO

Two hard limits on tvOS rule out every common approach:

| Attempt | Measured result |
|---|---|
| launchd `Sockets` + `inetdCompatibility` / `OnDemand` | The socket gets created, but when a connection arrives `runs = 0` — launchd **never** spawns a child |
| In-process `fork()` / `posix_spawn_file_actions_*` | The SDK marks them `unavailable`; compilation fails outright |
| `popen()` | Depends on `/bin/sh` internally, which does not exist under some vroot layouts |

So privileged work can only be done by a **launchd-managed shell process**, and the front ends talk
to it through **file I/O**:

```
client → /var/run/tsltv/req.fifo   "<id>\t<verb> [args…]"
engine → <id>.out (stdout+stderr merged) / <id>.rc (exit code) / <id>.done (completion marker)
client → polls <id>.done, reads the result back, then cleans up
```

Security constraints: a verb whitelist (`install` / `uninstall` / `verify` / `probe` / `trust` /
`refresh` / `registration` / `version` / `inbox*` / `selfupdate` / `launch`), and any shell
metacharacter in a command (`; | & $ ( ) < > ' " \``) is rejected outright. There is no `eval`.

**Performance**: a single round trip carries a fixed cost of about 1.5 seconds (the engine is a
serial shell). Hence:

- `probe` (list data) is cached for **30 seconds** on the engine side and invalidated after any write
- the engine **pre-warms** the `probe` cache at startup, so the UI is hot when it opens (13.8s → 1.3s)
- Mach-O precheck dumps the file once with `od` and scans it linearly with `awk` (instead of forking `od` per load command: 16.8s → sub-second)

---

## 4. Full flow for installing one ipa

```
1. Unpack (unzip) into /var/tmp/tsltv.work/unpack
2. Read iTunesMetadata.plist (optional) → show the original app name/version
3. Precheck: parse LC_BUILD_VERSION / LC_ENCRYPTION_INFO_64 from the main executable header
     - cryptid != 0  → reject (encrypted bundle)
     - platform = 2  → warn (iOS bundle)
     - minos > 17.0  → warn (OS version too new)
4. Copy to /Applications/<Name>.app; recursively remove SC_Info / _CodeSignature from the main bundle and nested appex/frameworks; apply upstream-style Info.plist patches (SBAppUsesLocalNotifications=1, strip URL schemes claimed by real system apps)
5. Read each bundle's original entitlements and normalize container fields (fallback to TROLLTROLL.* only when the main app has none; Lite writes pmap_cs)
6. Walk every Mach-O (main executable + Frameworks + PlugIns + appex):
     each bundle main executable is re-signed with its own entitlements; all other binaries use
     ldid -s merge signing (preserving existing entitlements) -> jbctl trustcache add
7. Align permissions (owner 33:33; files 0644, directories and Mach-Os 0755) -> tsreg register:
     MCM app-data container + LS dictionary (Entitlements / plugin table / App Groups / containerization), System by default
8. Write installed.tsv and drop a `.tsltv-tsreg` marker inside the app
     (refresh / mods use it so apps installed by the old uicache path are never container-migrated)
```

Path blacklist: `jbctl trustcache add` silently rejects paths under
`/var/containers/Bundle/Application/**`. If you hit that, copy the binary to `/var/tmp` first
(the cdhash is independent of the path), add it, then move it back.

---

## 5. Startup order and privileges

| Process | User | Started by | Notes |
|---|---|---|---|
| `tsltvd` | root | LaunchDaemon, `RunAtLoad` | Resident, handles requests serially |
| `tsltvweb` | root | LaunchDaemon, `RunAtLoad` | Listens on 8787 |
| `com.trollstorelite.tv.retrust` | root | LaunchDaemon, `RunAtLoad` | Replays trust from the manifest when the jailbreak starts |
| `TrollStoreLiteTV.app` | mobile | Home screen | Only talks to the engine over the FIFO; never does privileged work itself |

The launchd trap: if the plist is written as "exec the script directly + `KeepAlive=true`", launchd
reports `EX_CONFIG(78)` and never starts it. It has to look exactly like this:

```xml
<key>ProgramArguments</key><array><string>/bin/sh</string><string>/usr/libexec/…/tsltvd</string></array>
<key>ProcessType</key><string>Background</string>
<key>KeepAlive</key><false/>
<key>StandardOutPath</key><string>/var/log/…</string>
```

---

## 6. Security model

- **Write scope**: the data partition and jbroot only (`/Applications`, `/var/tmp`, `/usr/libexec/tsltv`,
  `/Library/LaunchDaemons`). Nothing writes to `/rootfs` (read-only system volume), the basebin or the kernel.
- **Irreversible operations**: `uninstall` only acts on entries with `origin=install` in `installed.tsv`;
  apps that came with the jailbreak (brought in as `adopt`) refuse to uninstall.
- **Command injection**: the engine whitelists verbs, rejects shell metacharacters in arguments, and
  never evaluates strings.
- **Permissions**: the FIFO directory is `0755` and `req.fifo` plus the response files are `0666` —
  so the GUI, which runs as mobile, can call in. This is a deliberate trade-off: any process on the
  device can call these **install/verify-grade** verbs (there is no arbitrary command execution).
  If you only use the CLI, change those two `chmod` calls in `tsltvd` back to `700/600` to restore strict mode.
- **No decryption**: encrypted (App Store) bundles are always rejected; this project contains no FairPlay bypass of any kind.
