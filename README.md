# Anilili for iOS

A native SwiftUI port of the Android app, built as a SwiftPM package with
[xtool](https://github.com/xtool-org/xtool). It is shared between the PC and the Mac through one
private remote and nowhere else; see `AGENTS.md`.

## Layout

- `Sources/AnililiCore`: Foundation only. AniList client, title/season matching, providers,
  watch history. Builds and tests on Linux.
- `Sources/Anilili`: the SwiftUI app (iOS 18+; Liquid Glass on iOS 26). Everything is behind `#if canImport(UIKit)`, so
  it compiles to nothing on Linux.
- `Tests/AnililiCoreTests`: Swift Testing. `Fixtures/parity-titles.json` is a copy of the
  Android app's `parity/titles.json`; keep them in step.

Ported so far: the Android app's theme engine and design system (dynamic themes, glass,
poster cards) under the system tab bar, Home, Browse with filters, Schedule, My List, Settings
(Appearance in full), and a show page and AVKit player with sub/dub, skip and failover. The full
feature-by-feature status and the remaining phases are in `docs/PARITY.md`.

## Test the core on Windows (WSL)

Ubuntu-24.04 has Swift 6.4 (swiftly) and xtool under the `dev` user. Building on `/mnt/c` is
slow, so sync into the Linux filesystem first:

```bash
wsl -d Ubuntu-24.04 -- bash -lc 'rsync -a --delete --exclude .git --exclude .build /mnt/c/Users/Admin/Documents/anilili-ios/ ~/src/anilili-ios/ && cd ~/src/anilili-ios && swift test'
```

Live checks against AniList and AnimeHeaven are off by default: add `ANILILI_LIVE=1` and
`--filter Live`. `--filter AdultLive` checks the adult servers on Imaizumin-chi (132203); Hentai
Haven's part runs only on the Mac, since its Cloudflare challenges Linux's TLS.

## Run the app on the MacBook (iOS Simulator)

1. Install Xcode and launch it once, then install xtool: `brew install xtool-org/tap/xtool`.
2. Clone `origin` (the private repo) and, before any commit there, set the committer identity
   and copy the `pre-push` hook from the PC's `.git/hooks` (see `AGENTS.md`). Afterwards,
   `git pull` picks up work done on the PC.
3. Boot a simulator (`open -a Simulator`), then in the repo run `scripts/run-simulator.sh`
   (optionally with the simulator's UDID). It runs `xtool dev run --simulator`, which builds and
   installs with no Apple ID, then corrects the SDK version recorded in the binary and launches
   the app. Without that step xtool's binary claims the iOS 18 SDK, and iOS 26 shows the app in
   its old look (no Liquid Glass tab bar or bars); the script's comment has the details.
4. To debug in Xcode instead: `xtool dev generate-xcode-project`, then open the project it
   writes under `xtool/`.

### Debugging on the Mac

Every network request, provider decision and player event is logged (`Sources/AnililiCore/Debug/Log.swift`):

- **In the app:** Settings → App → Debug log. Filter by level, then **Copy** (or Share) to paste
  the whole log, with device and version on top, into a bug report or a chat.
- **Player overlay:** Settings → Player debug overlay shows the current server, its state and
  AVFoundation's last error over the video. When nothing plays, the error screen lists every
  server tried and why each failed.
- **Live in Terminal:** launch with the console attached and every `[Anilili]` line streams out:
  `xcrun simctl launch --console-pty booted com.anilili.ios`
- **After the fact:** the same lines are in the unified log, beside AVFoundation's, for a bug
  report: `xcrun simctl spawn booted log show --last 30m --predicate 'subsystem == "com.anilili.ios" OR process == "Anilili"' > report.log`
- **Build errors:** `scripts/run-simulator.sh 2>&1 | tee build.log` keeps them for pasting
  (`xtool dev build` has no `--simulator` flag).
- **Accounts:** Settings → Accounts & sync. Sign-in runs in a web view inside the app; the log's
  `account` lines show the refresh, every list write and anything AniList or MyAnimeList refused.
  If the simulator build has no Keychain access, the log says so and the token is kept in app
  storage instead, so sign-in still works there.

The app target uses Swift 5 language mode until it has compiled cleanly against the iOS SDK
once; switch it to Swift 6 in `Package.swift` after fixing whatever strict concurrency reports.

## Install on an iPhone

On the Mac, `scripts/build-ipa.sh` builds an unsigned `xtool/Anilili.ipa` with Xcode (xtool
generates the project; the script adds the icons the generated project leaves out). It still
has to be signed for the phone: a sideloading tool that signs with your Apple ID does that while
installing (Xcode's Devices window only takes signed builds). Free Apple IDs re-sign every 7 days. Xcode records the real
SDK in the binary, so the phone gets iOS 26's look; `xtool dev` on its own does not (see
`scripts/run-simulator.sh`).

**Version and build** are `CFBundleShortVersionString` and `CFBundleVersion` in
`Resources/Info.plist` (Settings → App → Version shows both). Raise `CFBundleVersion` by one for
every IPA handed out, and the version for a release: the usage ping (`docs/USAGE-PING.md`) reports
both, and a device only counts as updated when one of them changed.

The app reads the expiry from the profile the sideloading tool embeds (`embedded.mobileprovision`):
Home shows a banner from two days out, Settings → App shows the date, and a notification goes out
at 10:00 the day before (Settings → Notifications turns it off). Simulator builds have no
profile, so none of this appears there.

Nothing in the IPA names the Mac that built it or its owner: the script strips symbols and the
build paths they carry, renames the checkout-named resource bundle, and drops the Mac's OS build
and the zip's owner ids. It then searches every file for the user, real, computer and host names,
the checkout folder, the Git identity and the remote's account and repository, and refuses to
package on any hit. `xtool dev` installs skip all of this; build anything you hand out with the
script.

From xtool alone: `xtool setup` (Apple ID or App Store Connect API key), then `xtool dev` with the
phone plugged in. From WSL this also needs the iOS SDK
(`xtool sdk install <path to Xcode.xip>`, downloaded by hand from developer.apple.com) and USB
passthrough via usbipd.
