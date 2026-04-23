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

# If no notes file was provided, pop up the user's editor with a template.
# Mirrors `git commit` — empty/unsaved → abort the release. HTML comments are
# used for instructions so markdown headings in the notes aren't misread as
# comments.
if [ -z "${NOTES_FILE}" ]; then
  EDITOR_CMD="${VISUAL:-${EDITOR:-}}"
  if [ -z "${EDITOR_CMD}" ]; then
    for candidate in nano vi; do
      if command -v "${candidate}" >/dev/null 2>&1; then
        EDITOR_CMD="${candidate}"
        break
      fi
    done
  fi
  if [ -z "${EDITOR_CMD}" ]; then
    echo "No editor found. Set \$VISUAL or \$EDITOR, or pass --notes <path>." >&2
    exit 1
  fi

  NOTES_DIR="$(mktemp -d)"
  NOTES_FILE="${NOTES_DIR}/release-notes-${TAG}.md"
  cat > "${NOTES_FILE}" <<'EOF'
## What's new

-

<!--
Write your release notes in Markdown above this block.
Everything inside HTML comments (including this one) will be stripped out.

Leave the file empty — or close without saving — to cancel the release.
-->
EOF

  BEFORE_MTIME="$(stat -f "%m" "${NOTES_FILE}")"
  "${EDITOR_CMD}" "${NOTES_FILE}"
  AFTER_MTIME="$(stat -f "%m" "${NOTES_FILE}")"

  if [ "${BEFORE_MTIME}" = "${AFTER_MTIME}" ]; then
    echo "Release notes untouched — cancelling release." >&2
    exit 1
  fi

  STRIPPED="$(perl -0777 -pe 's/<!--.*?-->//gs' "${NOTES_FILE}")"
  if [ -z "$(printf '%s' "${STRIPPED}" | tr -d '[:space:]')" ]; then
    echo "Release notes are empty — cancelling release." >&2
    exit 1
  fi
  printf '%s' "${STRIPPED}" > "${NOTES_FILE}"
fi

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
