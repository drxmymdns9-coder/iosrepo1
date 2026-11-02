# Working in this repository

Anilili for iOS: a native SwiftUI port of the Android app in `../miruro-apk`. Build, test and
run steps are in `README.md`.

## Rules

- **One private remote, nowhere else.** The code is shared between the developer's PC and Mac
  through one private GitHub repository, `origin` (set up 2026-10-11; its name says nothing about
  the app, and nothing in this repo names the account). Pushing there is fine; nothing else: no
  other remotes, no public repository, no pull requests or forks, no CI service, no uploading the
  source, a bundle or an archive anywhere else. The local `pre-push` hook refuses any other
  remote; never bypass it with `--no-verify`.
- **The Android repo is never pushed.** `../miruro-apk` (the mobile and TV flavors) has no
  push of any kind; its own `pre-push` hook refuses. Copying from it into this repo is fine
  whenever that's convenient (assets, fixtures, docs, logic to port).
- **Commit as `sanilili <338052299+sanilili@users.noreply.github.com>`, and only that.** Check
  `git config --show-origin user.name` and `user.email` before the first commit in any clone: a
  fresh clone (the Mac's included) has no identity in its `.git/config` and no `pre-push` hook, so
  set both up there before committing or pushing.
- **Builds name nobody.** No IPA or app bundle may contain the build machine's user, real,
  computer or host name, its paths, the checkout folder, or the Git or GitHub identity. Build
  anything handed out with `scripts/build-ipa.sh`, whose final check refuses to package on any
  hit; never weaken or skip that check, and never write those names into the repo to test for
  them (the script reads them at build time).
- **Stage explicit paths.** Check `git status` before every commit.
- **Keep parsing in `AnililiCore`**, Foundation only, with tests that run on Linux. The app
  target is SwiftUI and only compiles against the iOS SDK.
- **Releasing follows the private release runbook**, kept outside this repo with every host and
  account in it (never copy any of it in here). The part that lives here: raise `CFBundleVersion`
  in `Resources/Info.plist` by one for every IPA handed out (and the version for a new release),
  commit only that as "Version <v>, build <N>", push to `origin`, then on the Mac build from a
  clean, pushed `HEAD` with `scripts/build-ipa.sh release` and nothing else. The IPA, and the iOS
  changelog that goes with it, are published under the runbook's accounts, never as this repo's
  owner. The changelog is written for viewers: no account, repo or machine names, paths or
  hashes. "Bump build and push" means that whole sequence.
- **"Push to users" means ship it to testers**, not `git push`: the runbook's whole iOS release,
  every step through the signed update manifest and the private record, so installed apps offer
  the build. Bump only if `HEAD` isn't already an unreleased "Version <v>, build <N>" commit, and
  write the iOS changelog from the previous published entry. A plain "push" is still only
  `git push origin`.
- **Title matching must agree with Android and the desktop.** `Tests/AnililiCoreTests/Fixtures/
  parity-titles.json` is a copy of Android's `parity/titles.json`; update the two together.
