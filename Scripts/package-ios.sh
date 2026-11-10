#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
output_dir="${OUTPUT_DIR:-$project_dir/..}"
mkdir -p "$output_dir" "$project_dir/.build"
output_dir="${output_dir:A}"
work_dir="$(mktemp -d "$project_dir/.build/ios-package.XXXXXX")"
# Keep the archive and build log for local verification. They are ignored by Git.
xcodebuild -project Apps/iOS/BilibiliNEXT.xcodeproj -scheme BilibiliNEXT \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$project_dir/.build/ios-release" \
  -archivePath "$work_dir/BilibiliNEXT.xcarchive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  DEVELOPMENT_TEAM='' archive > "$work_dir/archive.log" 2>&1 || {
    tail -80 "$work_dir/archive.log"
    exit 1
  }
app_dir="$work_dir/BilibiliNEXT.xcarchive/Products/Applications/BilibiliNEXT.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Info.plist")"
mkdir -p "$work_dir/package/Payload"
ditto "$app_dir" "$work_dir/package/Payload/BilibiliNEXT.app"
python3 - "$work_dir/package/Payload/BilibiliNEXT.app" <<'PY'
from pathlib import Path
import plistlib, subprocess, sys
app = Path(sys.argv[1])
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS'], info['CFBundleSupportedPlatforms']
assert info['UIDeviceFamily'] == [1, 2], info['UIDeviceFamily']
assert not list(app.rglob('*.mobileprovision')), 'Unexpected provisioning profile'
assert not list(app.rglob('_CodeSignature')), 'Unexpected signing resources'
assert not list(app.rglob('*.p12')), 'Unexpected signing certificate'
binary = app / info['CFBundleExecutable']
assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip() == 'arm64'
for name in ['LICENSE.txt', 'BiliKit-LICENSE.txt', 'THIRD_PARTY.md']:
    assert (app / name).is_file(), name
(app / 'Info.plist').write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML))
print('Verified unsigned arm64 device app, iPhone/iPad support and bundled licenses.')
PY
# A certificate-free ad-hoc seal supplies the normal Mach-O signature command
# and CodeResources expected by re-signers. This is not an installable signature.
codesign --force --sign - --timestamp=none "$work_dir/package/Payload/BilibiliNEXT.app"
codesign --verify --deep --strict "$work_dir/package/Payload/BilibiliNEXT.app"
ipa="$output_dir/Bilibili-NEXT-$version-iOS-self-sign.ipa"
(cd "$work_dir/package" && COPYFILE_DISABLE=1 /usr/bin/zip -q -X -r "$work_dir/package.ipa" Payload)
/usr/bin/unzip -tq "$work_dir/package.ipa"
python3 Scripts/validate-ipa.py --portable "$work_dir/package.ipa"
mv -f "$work_dir/package.ipa" "$ipa"
printf '%s\n' "$ipa" "Archive log: $work_dir/archive.log"
