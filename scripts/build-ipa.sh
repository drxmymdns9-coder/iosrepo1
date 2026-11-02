#!/bin/sh
# Build an unsigned .ipa for a real iPhone with Xcode: xtool/Anilili.ipa.
# Usage: scripts/build-ipa.sh [debug|release]   (default release)
#
# xtool generates the Xcode project from Package.swift; xcodebuild then builds it for devices
# without signing. The .ipa still has to be signed for the phone: a sideloading tool that signs
# with your Apple ID does that while installing. (Xcode's Devices window only takes signed ones.)
#
# Two things the generated project leaves out are added here, the way `xtool dev` does them:
# the app icon and the ten alternate icons (xtool.yml `iconPath` and `resources:`) at the bundle
# root, with CFBundleIconFile. And the binary must record the real SDK: an app that claims an
# older SDK gets iOS 26's old look (see scripts/run-simulator.sh), so that is checked and fixed.
#
# Nothing in the IPA may name the Mac that built it or its owner; see the end of the script.
set -eu
cd "$(dirname "$0")/.."

case "${1:-release}" in
  debug) configuration=Debug ;;
  release) configuration=Release ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

xtool dev generate-xcode-project

derived=.build/xcode
xcodebuild \
  -workspace xtool/Anilili.xcworkspace \
  -scheme Anilili-App \
  -configuration "$configuration" \
  -destination generic/platform=iOS \
  -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO \
  build

app=$(find "$derived/Build/Products/$configuration-iphoneos" -maxdepth 1 -name "*.app" | head -n 1)
[ -n "$app" ] || { echo "no .app in $derived/Build/Products/$configuration-iphoneos" >&2; exit 1; }
plist="$app/Info.plist"
executable="$app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"

# Icons, as xtool places them.
cp Resources/AppIcon.png "$app/AppIcon.png"
cp Resources/AppIcons/AppIcon-*.png "$app/"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$plist"

# The SDK the binary claims to be built with.
sdk=$(xcrun --sdk iphoneos --show-sdk-version)
minos=$(xcrun vtool -show-build "$executable" | awk '/minos/ { print $2; exit }')
recorded=$(xcrun vtool -show-build "$executable" | awk '/ sdk / { print $2; exit }')
if [ "$recorded" != "$sdk" ]; then
  xcrun vtool -set-build-version ios "$minos" "$sdk" -replace -output "$executable.patched" "$executable"
  mv "$executable.patched" "$executable"
  echo "Recorded SDK changed from $recorded to $sdk"
fi
echo "Built for iOS $minos+, SDK $sdk: $app"

# Nothing in the IPA may say whose Mac built it. Symbols and linker debug maps carry the user
# name and the checkout's absolute paths; every Mach-O file is stripped of them. SwiftPM names the
# resource bundle after the checkout folder, so it gets the app's own identifier instead (it is
# found by path, not identifier). BuildMachineOSBuild is the Mac's exact macOS build.
find "$app" -type f | while read -r file; do
  if file -b "$file" | grep -q '^Mach-O'; then xcrun strip -S -x "$file"; fi
done
find "$app" -name Info.plist | while read -r info; do
  /usr/libexec/PlistBuddy -c 'Delete :BuildMachineOSBuild' "$info" 2>/dev/null || true
done
for bundle in "$app"/*.bundle; do
  [ -d "$bundle" ] || continue
  name=$(basename "$bundle" .bundle)
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.anilili.ios.resources.$name" "$bundle/Info.plist"
done
find "$app" -name .DS_Store -delete
xattr -cr "$app"

# Then every file is searched for this Mac and its owner: the user and real names, the computer
# and host names, the checkout folder, the Git identity and the remote's account and repository.
# They are read here, never written down, so the script names nobody. Any hit stops the build.
remote=$(git remote get-url origin 2>/dev/null | sed -E 's#^.*[:/]([^/]+)/([^/]+)$#\1 \2#; s#\.git$##' || true)
terms=$(printf '%s\n' "$(id -un)" "$(id -F 2>/dev/null)" "$HOME" \
  "$(scutil --get ComputerName 2>/dev/null)" "$(scutil --get LocalHostName 2>/dev/null)" "$(hostname -s)" \
  "$(basename "$(pwd)")" "$(git config user.name)" "$(git config user.email)" \
  "$(git config user.email | sed 's/@.*//; s/+.*//')" $remote |
  awk 'length($0) >= 4' | sort -u)
leaks=$(cd "$app" && {
  printf '%s\n' "$terms" | grep -rlaiF -f - . | sed 's/^/  matches this Mac or its owner: /'
  grep -rlaE '/Users/|/Volumes/|/home/|/private/var/folders/|/mnt/[a-z]/|[A-Za-z]:\\Users\\' . | sed 's/^/  has a build-machine path: /'
} || true)
if [ -n "$leaks" ]; then
  echo "The app names its build machine or owner; not packaging it:" >&2
  echo "$leaks" >&2
  exit 1
fi
echo "Checked: nothing in the app names this Mac or its owner"

rm -rf xtool/ipa
mkdir -p xtool/ipa/Payload
cp -R "$app" xtool/ipa/Payload/
rm -f xtool/Anilili.ipa
(cd xtool/ipa && zip -qryX ../Anilili.ipa Payload)  # -X: no owner uid/gid
rm -rf xtool/ipa
echo "IPA: $(pwd)/xtool/Anilili.ipa"
