[中文](../zh/APPS.md) · [English](APPS.md)

# App Installation Guide (Demo / Kodi / Browser / Userscripts)

This guide covers real tvOS apps verified on tvOS 17.0 + Relaxin/roothide with TrollStore Lite TV.

> Two recommended installation methods:
> - **Web store (easiest)**: open `http://<AppleTV-IP>:8787` in your browser and drag-and-drop the `.ipa` (shows live upload MB/s and device install timing).
> - **CLI**: `scp app.ipa mobile@<IP>:/var/tmp/ && ssh mobile@<IP> 'sudo tsltv install /var/tmp/app.ipa'`.

---

## 1. Bundled Demo App (`TSLTVDemo-unsigned.ipa`)

`TSLTVDemo` is the minimal unsigned tvOS app shipped with this repository (`examples/hello-tvos/`), complete with an inverted-palette tvOS icon. Use it to smoke-test the full install pipeline.

### Option A: Download from Releases

1. Download `TSLTVDemo-unsigned.ipa` from [GitHub Releases](https://github.com/comicchang/trollstore-lite-tv/releases).
2. Open `http://<AppleTV-IP>:8787` and drop `TSLTVDemo-unsigned.ipa` onto the upload zone.
3. Once you see `签名 1 / 信任 1 / 失败 0`, **TSLTV Demo** appears on the Apple TV Home Screen.

### Option B: Build locally on macOS

```sh
git clone https://github.com/comicchang/trollstore-lite-tv.git
cd trollstore-lite-tv
./examples/hello-tvos/build.sh
# Output: dist/TSLTVDemo-unsigned.ipa
```

Verify, launch, and uninstall:

```sh
ssh mobile@<IP> 'sudo tsltv verify com.example.tsltv.demo'
ssh mobile@<IP> 'sudo tsltv launch com.example.tsltv.demo'
ssh mobile@<IP> 'sudo tsltv uninstall com.example.tsltv.demo'
```

---

## 2. Kodi (Official tvOS Build)

Kodi publishes unencrypted tvOS builds (verified with **Kodi 21.3**).

### Convert the official `.deb` to `.ipa`

1. Download the official tvOS `.deb` from [kodi.tv/download/tvos](https://kodi.tv/download/tvos) (for example `org.xbmc.kodi-tvos_21.3-0_iphoneos-arm64.deb`).
2. Repack it as an `.ipa` on macOS/Linux:

```sh
mkdir -p /tmp/kodi-ipa/extract /tmp/kodi-ipa/Payload
dpkg-deb -x org.xbmc.kodi-tvos_*.deb /tmp/kodi-ipa/extract
mv /tmp/kodi-ipa/extract/Applications/Kodi.app /tmp/kodi-ipa/Payload/
(cd /tmp/kodi-ipa && zip -qr0 Kodi-tvOS.ipa Payload)
```

> Tip: `-0` (store without recompression) makes unpacking on the Apple TV much faster.

### Install on Apple TV

Drop `Kodi-tvOS.ipa` into `http://<AppleTV-IP>:8787` (or run `tsltv install`).
- Kodi ships ~12,000+ files and 151 Mach-O dylibs; v2.1.5+ uses the single-process `machoscan` C scanner, O(1) same-volume `mv`, and 4-way parallel signing/trustcache injection.
- v2.1.6+ `tsltv trust retrust` also replays all 151 embedded dylibs after a reboot + re-jailbreak.
- For multi-device SMB + shared MariaDB library/search sync and onboarding future devices, see [KODI-SYNC.md](KODI-SYNC.md).

### Troubleshooting: Kodi opens to a black screen

If Kodi stays running with a black screen and `/var/mobile/Library/Caches/kodi.log` reports `GUI format 0x0` or `LoadTTF` errors, an old `guisettings.xml` entry is pinning a mode that tvOS did not enumerate. Strip those two lines and cold-restart Kodi (restores `1920x1080 @ 60.00Hz`):

```sh
ssh mobile@<IP> '
  GS=/var/mobile/Library/Caches/Kodi/userdata/guisettings.xml
  cp "$GS" "${GS}.bak"
  grep -vE "videoscreen\.(resolution|screenmode)" "${GS}.bak" > "$GS"
  killall -9 Kodi 2>/dev/null || true
'
```

---

## 3. tvOS Web Browser (`jvanakker/tvOSBrowser`)

tvOS does not include Safari. The open-source [`jvanakker/tvOSBrowser`](https://github.com/jvanakker/tvOSBrowser) uses tvOS private `WKWebView` APIs to provide tabs and fullscreen video playback (verified on tvOS 17.0).

Build an unsigned `.ipa` on macOS with Xcode:

```sh
git clone --depth 1 https://github.com/jvanakker/tvOSBrowser.git /tmp/tvOSBrowser
xcodebuild -project /tmp/tvOSBrowser/_Project/Browser.xcodeproj \
  -scheme Browser -sdk appletvos -configuration Release \
  -derivedDataPath /tmp/tvOSBrowser-build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

mkdir -p /tmp/tvOSBrowser-ipa/Payload
cp -a /tmp/tvOSBrowser-build/Build/Products/Release-appletvos/Browser.app /tmp/tvOSBrowser-ipa/Payload/
(cd /tmp/tvOSBrowser-ipa && zip -qr tvOSBrowser.ipa Payload)
```

Drop `tvOSBrowser.ipa` into `http://<AppleTV-IP>:8787` (**tvOS Browser** will appear on the Home Screen).

---

## 4. Built-in Userscript Host (Web Store `:8787`)

Since **v2.1.6**, the web store includes a local Tampermonkey-style userscript host persisted at `/var/mobile/Library/tsltv-userscripts/`:

- **Bundle endpoint**: `http://127.0.0.1:8787/api/userscripts.js` (concatenates all enabled `*.js` files in sorted order inside isolated `try/catch` IIFEs, serves `Access-Control-Allow-Origin: *`, and tracks fetch count & last pull time).
- **Management**: Upload, toggle, or delete `.js` scripts directly from the bottom section of `http://<AppleTV-IP>:8787/` — no IPA repackaging required.
- **Typical use**: Pair with web-shell / Cobalt apps patched to load `http://127.0.0.1:8787/api/userscripts.js` for instant, offline-first script loading without relying on external CDNs.

---

## 5. Encrypted App Store Packages

`tsltv` does **not** perform FairPlay decryption and rejects encrypted IPAs (`cryptid≠0`) before installation. If you are patching your own legally obtained tvOS IPA for personal userscript injection, use a separate standalone patcher workflow.
