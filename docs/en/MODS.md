[中文](../zh/MODS.md) · [English](MODS.md)

# Mods (native dylib injection)

The idea is the same as Tampermonkey: let users drop in external code that changes how
an app behaves. The difference is that **tvOS has no injectable JS runtime** — a "mod"
here is a native dylib, placed in the app's `Frameworks/` and loaded by the main binary.
The mechanism is the same as TrollFools.

## What it does

```
<App>.app/
  YouTubeUnstable          ← main binary, one extra LC_LOAD_DYLIB
  Frameworks/libxxx.dylib  ← the mod (arm64 tvOS, must be signed)
```

`tools/inject_dylib.py` inserts
`LC_LOAD_DYLIB @executable_path/Frameworks/libxxx.dylib` into the Mach-O load commands
in place:

```sh
python3 tools/inject_dylib.py \
  /Applications/Foo.app/Foo \
  @executable_path/Frameworks/libmod.dylib
```

It only edits the load commands. The signature becomes invalid and must be redone
(the installer handles that).

## Install a mod with the CLI (on device)

```sh
tsltv mods list                              # which apps already carry dylibs
tsltv mods apply com.google.ios.youtube.tvl /var/tmp/libmod.dylib
```

`mods apply` does four things: copy the dylib into `Frameworks/`, run `modinject` to add
`LC_LOAD_DYLIB`, re-sign the main binary and the dylib, then refresh the trust cache and
LaunchServices registration.

> To remove a mod: **reinstall the app**. This tool does not remove load commands
> (editing them back is riskier than reinstalling).

## Full workflow (manual)

```sh
# 1. build the mod (tvOS arm64 only)
xcrun --sdk appletvos clang -target arm64-apple-tvos17.0 -dynamiclib \
      -framework Foundation mod.m -o libmod.dylib

# 2. drop it into the app's Frameworks/
cp libmod.dylib Foo.app/Frameworks/

# 3. inject
python3 tools/inject_dylib.py Foo.app/Foo @executable_path/Frameworks/libmod.dylib

# 4. package and install
zip -qr Foo-modded.ipa Payload
tsltv install Foo-modded.ipa
```

## Limitations

| Limitation | Detail |
|---|---|
| Platform must match | the dylib must be `platform=3` (tvOS), arm64, like the host |
| Signatures | injection invalidates the signature; `tsltv install` re-signs both |
| Header space | insertion needs free space after the load commands (usually a few hundred bytes) |
| No DRM apps | a decrypted App Store app still needs FairPlay keys; a mod cannot fix that |
| Stability | a crashing mod crashes the app; there is no sandbox isolation |

## Difference from userscripts & Cobalt injection path

Tampermonkey scripts are JS running inside a page. A mod here is **native code inside
the process** — more capable and more dangerous.

For web-shell apps such as YouTube TV (`YouTubeUnstable`), binary inspection confirms it
does **not** use Apple's `WKWebView`/`UIWebView` — it runs Google's **Cobalt + Starboard + V8**
HTML5 engine loading `https://www.youtube.com/tv`. Therefore:

- Standard ObjC `WKWebView` swizzling has no effect on YouTube TV;
- Tampermonkey-style JS userscript injection works by hooking Cobalt's C++ script loader
  and CSP parser (`HTMLScriptElement::Execute` + `DirectiveList::AddDirective`) to whitelist
  script origins and inject a userscript loader (for example `Exaphis/mutube` + `TizenTube Cobalt`
  for ad-blocking, SponsorBlock, and 4K fixes on YouTube 4.54.01, then permanently installed
  via `tsltv` without 7-day resigning).

## Status

- ✅ The CLI includes `tsltv mods list` and `tsltv mods apply` (since 2.1.3).
- ⚠️ The v2.1.4 handover reports `EPERM` from device-side `mods apply`; a v2.1.5 device recheck is pending. There is still no mod registry or one-click catalog.
