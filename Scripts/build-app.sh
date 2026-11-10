#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
bin_dir="$(swift build -c release --show-bin-path)"
swift build -c release
app_dir="${APP_DIR:-$project_dir/../Bilibili NEXT.app}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/Frameworks"
sparkle_framework="$project_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$sparkle_framework" ]]; then
  print -u2 'Sparkle.framework is missing; resolve Swift packages before packaging.'
  exit 1
fi
ditto "$sparkle_framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
cp "$bin_dir/BiliGlass" "$app_dir/Contents/MacOS/BiliGlass.new"
mv -f "$app_dir/Contents/MacOS/BiliGlass.new" "$app_dir/Contents/MacOS/BiliGlass"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BiliGlass</string>
<key>CFBundleIdentifier</key><string>local.BiliGlass</string>
<key>CFBundleName</key><string>Bilibili NEXT</string>
<key>CFBundleDisplayName</key><string>Bilibili NEXT</string>
<key>CFBundleIconFile</key><string>AppIcon-Flat</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.4</string>
<key>CFBundleVersion</key><string>15</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
python3 - "$app_dir/Contents/Info.plist" "${UPDATE_REPOSITORY:-wzk112/Bilibili-NEXT}" "${SPARKLE_PUBLIC_ED_KEY:-}" "${UPDATE_FEED_URL:-}" <<'PY'
import base64, plistlib, re, sys, urllib.parse
path, repository, key, feed = sys.argv[1:]
if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
    raise SystemExit('Invalid update repository')
with open(path, 'rb') as f:
    info = plistlib.load(f)
info['BiliUpdateRepository'] = repository
info['SUEnableAutomaticChecks'] = False
info['SUAutomaticallyUpdate'] = False
if key:
    if len(base64.b64decode(key, validate=True)) != 32:
        raise SystemExit('SPARKLE_PUBLIC_ED_KEY must contain the 32-byte public key')
    feed = feed or f'https://github.com/{repository}/releases/latest/download/appcast.xml'
    url = urllib.parse.urlsplit(feed)
    if url.scheme != 'https' or not url.hostname or url.username or url.password:
        raise SystemExit('UPDATE_FEED_URL must be an HTTPS URL')
    info.update(SUPublicEDKey=key, SUFeedURL=feed, SUVerifyUpdateBeforeExtraction=True,
                SURequireSignedFeed=True, SUAllowsAutomaticUpdates=True)
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PY
cp Scripts/AppIcon.icns "$app_dir/Contents/Resources/AppIcon-Flat.icns"
rm -f "$app_dir/Contents/Resources/AppIcon.icns"
cp Vendor/BiliKitCore/LICENSE "$app_dir/Contents/Resources/BiliKit-LICENSE.txt"
cp LICENSE "$app_dir/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY.md "$app_dir/Contents/Resources/THIRD_PARTY.md"
cp "$project_dir/.build/artifacts/sparkle/Sparkle/LICENSE" "$app_dir/Contents/Resources/Sparkle-LICENSE.txt"
cp CHANGELOG.md "$app_dir/Contents/Resources/CHANGELOG.md"
signing_identity="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
if [[ -z "$signing_identity" ]]; then signing_identity="-"; fi
sign_options=(--force --sign "$signing_identity")
if [[ "${SIGNING_TIMESTAMP:-0}" == "1" ]]; then sign_options+=(--timestamp); else sign_options+=(--timestamp=none); fi
if [[ "$signing_identity" == "-" ]]; then sign_options+=(--options 0); else sign_options+=(--options runtime); fi
sparkle_bundle="$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B"
for helper in "$sparkle_bundle/XPCServices/Installer.xpc" "$sparkle_bundle/XPCServices/Downloader.xpc" "$sparkle_bundle/Updater.app" "$sparkle_bundle/Autoupdate"; do
  if [[ -e "$helper" ]]; then
    codesign "${sign_options[@]}" --preserve-metadata=entitlements "$helper"
  fi
done
codesign "${sign_options[@]}" --preserve-metadata=entitlements "$app_dir/Contents/Frameworks/Sparkle.framework"
codesign "${sign_options[@]}" "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
