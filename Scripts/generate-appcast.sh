#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
archives_dir="${1:?Usage: generate-appcast.sh ARCHIVES_DIRECTORY}"
repository="${UPDATE_REPOSITORY:-wzk112/Bilibili-NEXT}"
tag="${RELEASE_TAG:?Set RELEASE_TAG to the GitHub release tag}"
tool="$project_dir/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ ! -x "$tool" ]]; then
  print -u2 'Run swift package resolve first.'
  exit 1
fi
args=(--download-url-prefix "https://github.com/$repository/releases/download/$tag/" --link "https://github.com/$repository/releases/tag/$tag" --embed-release-notes)
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  args+=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
else
  args+=(--account "${SPARKLE_KEYCHAIN_ACCOUNT:-Bilibili-NEXT-updates}")
fi
"$tool" "${args[@]}" "$archives_dir"
