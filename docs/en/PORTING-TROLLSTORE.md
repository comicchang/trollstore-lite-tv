[中文](../zh/PORTING-TROLLSTORE.md) · English

# Porting TrollStore Lite TV's mechanism into TrollStore (Lite) — a field report

Goal: take TrollStore's install path off CoreTrust and onto "ad-hoc signing + kernel trust cache".
What follows are conclusions from things we **actually tried**, not speculation.

---

## 1. Upstream structure (from reading the source)

```
TrollStore.app  ──spawnRoot()──▶  RootHelper (a root binary)
                                   ├ install [force] [custom|installd] <ipa>
                                   ├ uninstall <bundle-id>
                                   ├ refresh / refresh-all
                                   ├ modify-registration <path> System|User
                                   └ enable-jit / url-scheme / reboot / …
```

The key point: **the app contains no install logic**. `-[TSApplicationsManager installIpa:]` just
assembles arguments and calls `spawnRoot(rootHelperPath(), args)`. All the real work lives in
`installApp()` in `RootHelper/main.m`:

1. Unpack (libarchive)
2. `ldid` signing + **CoreTrust fake-certificate bypass (fastPathSign)**
3. Create a container with `MCMAppContainer`, copy into `/var/containers/Bundle/Application/<UUID>/`
4. Write `.TrollStorePersistenceHelper`
5. Register with `uicache -p` (`registerPath()`)

---

## 2. Why it neither compiles nor runs on this machine

| Dependency | Actual situation on tvOS 17.0 |
|---|---|
| `posix_spawn` / `posix_spawn_file_actions_*` | The SDK marks them `unavailable`; compilation fails outright (`spawnRoot()` and `killall()` in RootHelper are both dead) |
| `posix_spawnattr_set_persona_*` | Same |
| `MCMAppContainer` / `MCMAppDataContainer` | The classes do not exist (statically compared against the tvOS SDK: missing) |
| `PSListController` / `PSSpecifier` | Do not exist; the entire settings UI is unusable |
| **CoreTrust (CVE-2023-41991)** | The forgery succeeds but `CS_INVALID_ALLOWED` is never set → even if installed, it will not start |

So "fork upstream and add a tvOS target" is a dead end — and not for lack of trying.

---

## 3. What actually works: replace the bottom layer, keep the interface

Since tvOS **cannot fork/exec**, privileged work has to be done by a launchd-managed **shell
process** (the only viable shape we found). The minimal port is therefore:

**Replace `RootHelper` with a shell script that implements the same subcommands.**

`tsh` in this directory is that script, and its interface maps one to one onto upstream:

```sh
tsh install [force] [custom|installd] <ipa|tipa|app>
tsh uninstall <bundle-id>
tsh refresh            # re-register installed apps (uicache -p)
tsh refresh-all        # uicache -a
tsh registration <bid> # inspect System/User
tsh trust-retrust      # replay the trust cache from the manifest
```

The change to TrollStore's source is a single spot (illustrative):

```diff
--- a/TrollStore/TSApplicationsManager.m
+++ b/TrollStore/TSApplicationsManager.m
@@
-    int ret = spawnRoot(rootHelperPath(), args, nil, logOut);
+    // tvOS: no exec — hand the request to a resident engine (FIFO) and let the
+    //       launchd-managed tsltvd run it; refresh the app list on success
+    int ret = tsltvRequest(args);   // writes to /var/run/tsltv/req.fifo
```

`tsltvRequest()` is implemented with pure file I/O (write to the FIFO → poll `.done` → read
`.out`) and needs none of the banned APIs. That is exactly what we do on the GUI side; see
`ATRun()` in `../gui/main.m`.

---

## 4. Measured: the interface layer already works

Driving our implementation with TrollStore's **original invocation form** (on the device):

```
$ tsh install custom /var/tmp/ForkTest.ipa
[tsh] TrollStore-compatible install (args: custom)
    metadata: Fork Test App v1.2.3          ← reads iTunesMetadata.plist
    probe: platform=3 minos=17.0 cryptid=0  ← pre-install check (encrypted bundles rejected outright)
==> com.trollstorelite.tv.forktest
==> signed 1 / trusted 1 / failed 0
    cdhash: 69071878bcbd3c6c8f0679768615c7ed022c0a71

$ tsh registration com.trollstorelite.tv.forktest
Name: ForkTest / Bundle Identifier: com.trollstorelite.tv.forktest / …

$ tsh uninstall com.trollstorelite.tv.forktest
==> done
```

In other words: **the underlying mechanism can already be swapped in**; what is left is UI work —
and the UI layer has to be rewritten on tvOS anyway (the private frameworks are missing). We
rewrote it as `TrollStoreLiteTV.app`.

---

## 5. Conclusions

- ✅ **The mechanism is portable**: `tsh` already runs install/uninstall/registration queries using upstream's calling convention
- ✅ **The trust-cache logic is worth adding**: upstream relies on CoreTrust, we rely on `jbctl trustcache add`, which is measured to be the only workable path on tvOS; replay at boot is handled by a LaunchDaemon
- ❌ **A whole-package fork is not viable**: `posix_spawn` is banned + `MCMAppContainer` is missing + CoreTrust is ineffective
- ⚠️ **The UI cannot be copied over**: `PSListController`/`PSSpecifier` do not exist on tvOS, so upstream's settings page and some list controls are unusable
