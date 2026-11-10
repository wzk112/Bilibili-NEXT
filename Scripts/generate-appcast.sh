#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
if (( $# != 3 )); then
  print -u2 'Usage: Scripts/generate-appcast.sh <update-zip-directory> <release-tag> <output-appcast.xml>'
  exit 1
fi
archive_dir="${1:A}"
release_tag="$2"
output_file="${3:A}"
tool="$project_dir/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ ! -x "$tool" ]]; then (cd "$project_dir" && swift package resolve); fi
signing_args=(--account BilibiliNEXT)
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then signing_args=(--ed-key-file "$SPARKLE_ED_KEY_FILE"); fi
"$tool" "${signing_args[@]}" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/wzk112/Bilibili-NEXT/releases/download/$release_tag/" \
  --link 'https://github.com/wzk112/Bilibili-NEXT' "$archive_dir"
mkdir -p "${output_file:h}"
cp "$archive_dir/appcast.xml" "$output_file"
print "Signed appcast: $output_file"
