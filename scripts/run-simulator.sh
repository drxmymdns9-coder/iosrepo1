#!/bin/sh
# Build, install and launch the app in a booted iOS Simulator: `xtool dev run --simulator`, then
# the SDK version fix below. Usage: scripts/run-simulator.sh [simulator UDID]
#
# xtool's final link passes the SDK as `--sysroot`, but clang only reads the SDK version from
# `-isysroot`, so the binary records the deployment target (18.0) as the SDK it was built with.
# iOS keeps apps "built for" an older SDK in their old look: no Liquid Glass tab bar, bars or
# sheets on iOS 26. This rewrites the recorded SDK to the real one and re-signs (xtool's simulator
# signature is the linker's ad-hoc one, so nothing else is lost) before installing again.
set -eu
cd "$(dirname "$0")/.."

udid="${1:-}"
if [ -n "$udid" ]; then
  xtool dev run --simulator --udid "$udid"
else
  xtool dev run --simulator
fi

app=xtool/Anilili.app
binary="$app/Anilili"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
minos=$(xcrun vtool -show-build "$binary" | awk '/minos/ { print $2; exit }')
xcrun vtool -set-build-version iossim "$minos" "$sdk" -replace -output "$binary.patched" "$binary"
mv "$binary.patched" "$binary"
codesign --force --sign - "$app"
echo "Recorded SDK set to $sdk (deployment target $minos)"

target="${udid:-booted}"
xcrun simctl install "$target" "$app"
xcrun simctl launch "$target" com.anilili.ios
