#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
bin_dir="$(swift build -c release --show-bin-path)"
swift build -c release
app_dir="${APP_DIR:-$project_dir/../Bilibili NEXT.app}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
ditto "$project_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
cp "$bin_dir/BiliGlass" "$app_dir/Contents/MacOS/BiliGlass.new"
mv -f "$app_dir/Contents/MacOS/BiliGlass.new" "$app_dir/Contents/MacOS/BiliGlass"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string></array>
<key>CFBundleExecutable</key><string>BiliGlass</string>
<key>CFBundleIdentifier</key><string>local.BiliGlass</string>
<key>CFBundleName</key><string>Bilibili NEXT</string>
<key>CFBundleDisplayName</key><string>Bilibili NEXT</string>
<key>CFBundleIconFile</key><string>AppIcon-Flat</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.8</string>
<key>CFBundleVersion</key><string>20</string>
<key>SUFeedURL</key><string>https://github.com/wzk112/Bilibili-NEXT/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>96JKf6JdwWDEGZKlN9VaJk59A9Z+sVOGSolKB0DTekQ=</string>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUAllowsAutomaticUpdates</key><true/>
<key>SUAutomaticallyUpdate</key><false/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
cp Scripts/AppIcon.icns "$app_dir/Contents/Resources/AppIcon-Flat.icns"
rm -f "$app_dir/Contents/Resources/AppIcon.icns"
cp Vendor/BiliKitCore/LICENSE "$app_dir/Contents/Resources/BiliKit-LICENSE.txt"
cp LICENSE "$app_dir/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY.md "$app_dir/Contents/Resources/THIRD_PARTY.md"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app_dir/Contents/Resources/Sparkle-LICENSE.txt"
cp CHANGELOG.md "$app_dir/Contents/Resources/CHANGELOG.md"
signing_identity="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
if [[ -z "$signing_identity" ]]; then signing_identity="-"; fi
sparkle="$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$sparkle/XPCServices/Downloader.xpc" "$sparkle/XPCServices/Installer.xpc" "$sparkle/Autoupdate" "$sparkle/Updater.app" "$app_dir/Contents/Frameworks/Sparkle.framework"; do
  codesign --force --sign "$signing_identity" --timestamp=none --options runtime "$item"
done
codesign --force --sign "$signing_identity" --timestamp=none --options runtime "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
