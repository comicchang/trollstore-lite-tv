[中文](../zh/RELEASE.md) · English

# Release process

## Creating the repository for the first time

```sh
# 1) initialize locally
cd trollstore-lite-tv
git init && git add -A && git commit -m "feat: initial public release (v2.0.3)"

# 2) create the public repo with the GitHub CLI (recommended)
brew install gh       # if not installed
gh auth login         # interactive login, once
gh repo create trollstore-lite-tv --public --source=. --remote=origin --push \
  --description "TrollStore Lite TV - install and run unsigned tvOS apps on jailbroken Apple TV"

# or without gh: create an empty repo in the web UI, then
#   git remote add origin git@github.com:<you>/trollstore-lite-tv.git
#   git push -u origin main
```

### Repository metadata worth setting (it decides whether people can find you)

**Description**

> Unofficial TrollStore-Lite-style installer for jailbroken tvOS (Apple TV). Ad-hoc signing +
> kernel trust cache, no Apple certificate, no CoreTrust. TV UI + web store + CLI.

**Topics** (GitHub repo → About ⚙️ → Topics, up to 20)

```
trollstore  trollstore-lite  tvos  appletv  apple-tv  jailbreak  sideload
ipa  ldid  trustcache  roothide  relaxin  kodi  installer  objective-c
```

> Search matching looks mostly at **repo name + description + topics**. The name already contains
> "trollstore" and "tv"; with these topics, queries like "trollstore apple tv" / "tvos trollstore"
> will hit.

## Building a package without a device

```sh
brew install dpkg            # macOS; on Linux use apt install dpkg
./scripts/build-deb-local.sh # → dist/trollstore-lite-tv_<ver>_appletvos-arm64e.deb
```

CI's `package` job uses exactly this path (`--root-owner-group` ensures the package is owned by root:root).

## Publishing a new version

```sh
# One command: build locally and publish a GitHub Release (no device needed)
./scripts/publish-release.sh v2.1.5 dist/RELEASE-NOTES-v2.1.5.md

# Or manually step by step
./scripts/build-deb-local.sh && ./examples/hello-tvos/build.sh
gh release create v2.1.5 dist/trollstore-lite-tv_2.1.5_appletvos-arm64e.deb dist/TSLTVDemo-unsigned.ipa --notes-file dist/RELEASE-NOTES-v2.1.5.md
```

It will:

1. Build the `.deb` locally (`dist/trollstore-lite-tv_<ver>_appletvos-arm64e.deb`)
2. Build the unsigned demo ipa with a tvOS icon (`dist/TSLTVDemo-unsigned.ipa`)
3. Create the GitHub Release and upload both artifacts

## What a Release should contain

| Artifact | Notes |
|---|---|
| `trollstore-lite-tv_<ver>_appletvos-arm64e.deb` | Installer package. `sudo dpkg -i` is enough; `postinst` signs / trusts / registers / starts services automatically |
| `TSLTVDemo-unsigned.ipa` | Unsigned demo app used to verify the install chain; also a template for writing your own tvOS app |

Neither artifact **contains** any Apple signing material; signing happens on the device at install time.

## Version numbering convention

- Major (2.x): breaking changes such as renames, directory structure, package name
- Minor (x.1): new capabilities (new verbs, new front ends)
- Patch (x.x.1): fixes and documentation
