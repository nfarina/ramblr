#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./Scripts/publish-release.sh <version> [--notes path/to/notes.md]
#
# End-to-end release:
#   1. local-release-build.sh  → signed, notarized, stapled zip in dist/
#   2. Create GH release v<version>, attach the zip
#   3. generate-sparkle-appcast.sh → updates docs/appcast.xml
#   4. Commit and push docs/appcast.xml to main (GH Pages serves from main/docs)
#
# This script is intentionally opinionated about the release flow. Skip any
# step by running the underlying scripts individually.

if [ $# -lt 1 ]; then
  echo "Usage: $0 <version> [--notes path/to/notes.md]" >&2
  exit 1
fi

VERSION="${1#v}"
shift || true
NOTES_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes)
      [[ -n "${2:-}" ]] || { echo "--notes requires a path" >&2; exit 1; }
      NOTES_FILE="$2"
      shift 2
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

cd "$(dirname "$0")/.."

TAG="v${VERSION}"
ZIP_PATH="dist/Ramblr-${VERSION}-macos.zip"

command -v gh >/dev/null 2>&1 || { echo "The 'gh' CLI is required. brew install gh" >&2; exit 1; }

if [ ! -f "${ZIP_PATH}" ]; then
  echo "Building release…"
  ./Scripts/local-release-build.sh "${VERSION}"
fi

if gh release view "${TAG}" >/dev/null 2>&1; then
  echo "GH release ${TAG} already exists — uploading zip as an additional asset."
  gh release upload "${TAG}" "${ZIP_PATH}" --clobber
else
  echo "Creating GH release ${TAG}…"
  if [ -n "${NOTES_FILE}" ]; then
    gh release create "${TAG}" "${ZIP_PATH}" --title "${TAG}" --notes-file "${NOTES_FILE}"
  else
    gh release create "${TAG}" "${ZIP_PATH}" --title "${TAG}" --generate-notes
  fi
fi

echo "Updating appcast…"
APPCAST_ARGS=("${VERSION}")
[ -n "${NOTES_FILE}" ] && APPCAST_ARGS+=(--notes "${NOTES_FILE}")
./Scripts/generate-sparkle-appcast.sh "${APPCAST_ARGS[@]}"

echo "Committing release bump + appcast…"
git add Ramblr.xcodeproj/project.pbxproj docs/appcast.xml
if git diff --cached --quiet; then
  echo "Nothing to commit."
else
  git commit -m "Release ${TAG}"
  git push origin HEAD
fi

echo
echo "Published ${TAG}."
echo "  Zip:     ${ZIP_PATH}"
echo "  Release: https://github.com/nfarina/ramblr/releases/tag/${TAG}"
echo "  Feed:    https://nfarina.github.io/ramblr/appcast.xml"
