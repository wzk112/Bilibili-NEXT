#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  print -u2 'Commit the release source before packaging; the source archive must match the apps.'
  exit 1
fi
release_commit="$(git rev-parse HEAD)"
Scripts/build-app.sh
app_dir="${APP_DIR:-$project_dir/../Bilibili NEXT.app}"
output_dir="${OUTPUT_DIR:-$project_dir/..}"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
stem="Bilibili-NEXT-$version-macOS-arm64"
mkdir -p "$output_dir"
OUTPUT_DIR="$output_dir" Scripts/package-ios.sh
ios_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Apps/iOS/Info.plist)"
codesign --verify --deep --strict "$app_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$output_dir/$stem.zip"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/bilibili-next-release.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" && "${GENERATE_APPCAST:-1}" == "1" ]]; then
  mkdir -p "$stage_dir/appcast"
  cp "$output_dir/$stem.zip" "$stage_dir/appcast/$stem.zip"
  cp CHANGELOG.md "$stage_dir/appcast/$stem.md"
  RELEASE_TAG="${RELEASE_TAG:-v$version}" Scripts/generate-appcast.sh "$stage_dir/appcast"
  cp "$stage_dir/appcast/appcast.xml" "$output_dir/appcast.xml"
fi
mkdir -p "$stage_dir/dmg"
ditto "$app_dir" "$stage_dir/dmg/Bilibili NEXT.app"
ln -s /Applications "$stage_dir/dmg/Applications"
hdiutil create -volname 'Bilibili NEXT' -srcfolder "$stage_dir/dmg" -format UDZO -ov "$output_dir/$stem.dmg"
# Archive only committed source. Never package local build products, account data or media.
if [[ "$(git rev-parse HEAD)" != "$release_commit" || -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  print -u2 'Source changed while building. Commit the changes and rebuild the release.'
  exit 1
fi
git archive --format=zip --prefix="Bilibili-NEXT-$version/" -o "$output_dir/Bilibili-NEXT-source-$version.zip" "$release_commit"
(cd "$output_dir" && shasum -a 256 "$stem.zip" "$stem.dmg" "Bilibili-NEXT-$ios_version-iOS-self-sign.ipa" "Bilibili-NEXT-source-$version.zip" > "Bilibili-NEXT-$version-SHA256SUMS.txt")
printf '%s\n' "$output_dir/$stem.zip" "$output_dir/$stem.dmg"
