[中文](../zh/INSTALL.md) · English

# Install and usage

Audience: people who want to install third-party tvOS apps on a jailbroken Apple TV.

---

## 0. Prerequisites

| Item | Requirement |
|---|---|
| Device | Apple TV HD / 4K (the reference device for this project is an **Apple TV 4K 3rd gen A15**, `AppleTV14,1`) |
| OS | **tvOS 17.x** (tested on 17.0 / 21J354) |
| Jailbreak | **Relaxin** (roothide-family jailbreak) active, `roothide >= 0.1.0-5` |
| Access | You can SSH into the device (user `mobile` by default) and you have sudo |
| Host | macOS (for packaging) or any machine with `scp`/`ssh` |

Confirm the jailbreak is active:

```sh
ssh mobile@<device-ip> 'ls -d /var/containers/Bundle/Application/.jbroot-* && jbctl trustcache info | head -4'
```

You are good to go once you see a `.jbroot-<HASH>` directory and `Jailbreak trust caches / Status: complete`.
Every script in this project **auto-detects** that `.jbroot-*` directory name — you never have to fill in the hash yourself.

---

## 1. Install TrollStore Lite TV

### Option A: one command from a Mac (recommended)

```sh
git clone https://github.com/comicchang/trollstore-lite-tv.git
cd trollstore-lite-tv
ATV_PASS='<device sudo password>' ./scripts/install.sh 192.168.1.23
```

It uploads the deb → runs `dpkg -i` → waits for the daemon to come up → prints the three entry points and the self-check results.

### Option B: manual dpkg

```sh
scp dist/trollstore-lite-tv_<ver>_appletvos-arm64e.deb mobile@192.168.1.23:/var/tmp/
ssh mobile@192.168.1.23 'sudo dpkg -i /var/tmp/trollstore-lite-tv_<ver>_appletvos-arm64e.deb'
```

> `/var/tmp` has the sticky bit set, so if a file of the same name already exists and is owned by
> root, `scp` fails with `Permission denied`. Just use a different file name.

### What happens during installation

`postinst` performs four steps, none of them optional (rationale in [ARCHITECTURE](ARCHITECTURE.md)):

1. **Re-sign** `tsltvweb` / `wake` / `TrollStoreLiteTV.app` (`dpkg` overwrites the files and drops the signature applied at package build time)
2. Write their cdhashes, and the app's, into the **kernel trust cache**
3. `uicache -p` to register the TV app and create the `/usr/bin/{tsltv,trollstore-lite-tv,tsl}` aliases
4. Start three LaunchDaemons: `tsltvd` (engine), `tsltvweb` (web), `com.trollstorelite.tv.retrust` (replays trust at boot)

### Verify

```sh
ssh mobile@192.168.1.23 'sudo tsltv doctor'     # environment self-check
ssh mobile@192.168.1.23 'sudo tsltv verify'     # trust/registration/signature state per app
curl -sI http://192.168.1.23:8787/ | head -1        # is the web store up?
```

Or use the acceptance script in the repo (it builds a temporary app and runs install/verify/launch/uninstall end to end):

```sh
ATV_PASS='<sudo password>' ./scripts/accept.sh 192.168.1.23
```

Expected output:

```
PASS  daemon is running (waited 0s)
PASS  install succeeded: cdhash: 2271d0f4…
PASS  verification passed
PASS  launched by launchd: PID 12345 PPID 1
PASS  uninstalled cleanly
all passed ✅
```

---

## 2. Install your first app

### Command line

```sh
# local ipa
ssh mobile@192.168.1.23 'sudo tsltv install /var/tmp/kodi.ipa'

# hand it a URL (the device downloads it itself)
ssh mobile@192.168.1.23 'sudo tsltv install-url https://example.com/kodi.ipa'
```

A **precheck** runs before installation; you will see:

```
    metadata: Kodi v21.3                 ← from iTunesMetadata.plist inside the ipa
    probe: platform=3 minos=17.0 cryptid=0
==> signed 3 / trusted 3 / failed 0
    cdhash: 3b9be3f3571686ec71dec9829676cbbb40904ea4
```

- `cryptid=1` → rejected outright (an encrypted bundle is always killed by the kernel at launch on tvOS)
- `platform=2` → warning: "this is an iOS bundle"
- `minos>17.0` → warning: "OS version too new"

### Web (least effort)

Open `http://<device-ip>:8787` and drag the `.ipa` onto the page. The page also shows each app's
trust/registration state and version, and offers "verify all" and "update self" buttons.

### TV UI

**TrollStore Lite TV** on the home screen: the list shows installed apps; there are four buttons in the top right:

| Button | Purpose |
|---|---|
| Install IPA | Install from a direct link (typing a URL with the remote is painful) |
| **Install folder** | Install every ipa in the "drop folder" — best combined with `scp` |
| Verify all | Verify item by item and report in a dialog |
| Refresh | Re-fetch the list |

The reason for the **drop folder** is that entering URLs with the remote on a TV is painful:

```sh
scp myapp.ipa mobile@192.168.1.23:/var/tmp/tsltv-inbox/
```

Then tap "Install folder" on the TV: it installs everything and empties the folder.

---

## 3. Day-to-day cheat sheet

```sh
sudo tsltv list                  # installed manifest (with cdhash and origin)
sudo tsltv verify [bundle-id]    # check trust/registration/signature/entitlements
sudo tsltv uninstall <id>        # uninstall (only apps this tool installed)
sudo tsltv refresh               # re-register (use when an icon is missing or invisible)
sudo tsltv refresh --all         # rebuild every registration
sudo tsltv registration          # whether each app is registered as System or User
sudo tsltv version               # tool version
```

Aliases: `trollstore-lite-tv` / `tsl` are equivalent to `tsltv`.

TrollStore-style invocation (for people familiar with upstream):

```sh
tsh install custom /var/tmp/x.ipa
tsh uninstall com.example.app
tsh refresh-all
```

---

## 4. After a reboot

The trust cache is **injected by the jailbreak**, so after a full device reboot:

1. You have to run the **Relaxin** jailbreak again
2. Once the jailbreak is active, `com.trollstorelite.tv.retrust` re-injects every app in the manifest into the trust cache (`installed.tsv` is the single source of truth)
3. The apps themselves **do not need reinstalling**

> This step has been verified in isolation (manual replay: `replay done: ok=6 bad=0`), but the
> full "reboot → re-run jailbreak → launch app directly" chain still awaits an acceptance run with
> a human in front of the TV. See [ROADMAP](ROADMAP.md).

---

## 5. Uninstall

```sh
sudo dpkg -r trollstore-lite-tv
```

`prerm` stops the three daemons, unregisters the TV app and removes the aliases in `/usr/bin`.
It does **not** delete the other apps you installed (they live in `/Applications` and are not in dpkg's manifest).

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `uiopen` does nothing, the app won't start | The TV is asleep or has no display output. Inject a HID keypress once with `sudo /usr/libexec/tsltv/wake` to wake it, then retry |
| App crashes right after tapping it, no logs | Most likely an encrypted bundle or a too-high minOS. Run `sudo tsltv verify <id>` and check the precheck output |
| `scp` reports `Permission denied` for `/var/tmp` | Sticky bit plus a root-owned file of the same name. Use a different file name |
| No icon on the home screen | `sudo tsltv refresh`; if that fails, `sudo tsltv refresh --all` |
| Web store unreachable | `ps ax \| grep tsltvweb`; `launchctl print system/com.trollstorelite.tv.web` to see the exit code |
| `dpkg -i` reports an architecture mismatch | Make sure the package is `appletvos-arm64e`; if needed, `dpkg --add-architecture appletvos-arm64` |
| Web service doesn't start after install | Usually the signature got overwritten and `postinst` did not finish. Re-run `dpkg -i --force-confmiss`, or check `/var/log/tsltvweb.log` |

Debug logs:

```
/var/log/tsltvd.log        every request the engine received, with exit code
/var/log/tsltvweb.log      web service
/var/log/tsltv.daemon.log  trust replay at boot
```
