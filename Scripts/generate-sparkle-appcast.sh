#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./Scripts/generate-sparkle-appcast.sh <version> [--notes path/to/notes.md]
#
# Expects dist/Ramblr-<version>-macos.zip to exist (produced by
# local-release-build.sh). Writes the updated docs/appcast.xml containing the
# new entry with an EdDSA signature. If --notes is provided, the contents are
# embedded as HTML release notes.

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/sparkle-config.sh"

cd "$(dirname "$0")/.."

TOOLS_DIR="$("${SCRIPT_DIR}/ensure-sparkle-tools.sh")"
GENERATE_APPCAST_BIN="${TOOLS_DIR}/bin/generate_appcast"
ARCHIVE_PATH="dist/Ramblr-${VERSION}-macos.zip"
APPCAST_PATH="docs/appcast.xml"
RELEASE_TAG="v${VERSION}"
DOWNLOAD_URL_PREFIX="${SPARKLE_RELEASE_DOWNLOAD_BASE_URL}/${RELEASE_TAG}/"
RELEASE_NOTES_URL="${SPARKLE_RELEASES_URL}/tag/${RELEASE_TAG}"

if [ ! -f "${ARCHIVE_PATH}" ]; then
  echo "Archive not found: ${ARCHIVE_PATH}" >&2
  echo "Run ./Scripts/local-release-build.sh ${VERSION} first." >&2
  exit 1
fi

mkdir -p docs

STAGING_DIR="$(mktemp -d -t ramblr-appcast)"
trap 'rm -rf "${STAGING_DIR}"' EXIT

cp "${ARCHIVE_PATH}" "${STAGING_DIR}/"

if [ -n "${NOTES_FILE}" ]; then
  [ -f "${NOTES_FILE}" ] || { echo "Notes file not found: ${NOTES_FILE}" >&2; exit 1; }
  # generate_appcast looks for <zipname>.html/.md alongside each zip to embed
  # as release notes; prefer Markdown so GitHub-style formatting survives.
  cp "${NOTES_FILE}" "${STAGING_DIR}/Ramblr-${VERSION}-macos.md"
fi

# Preserve existing appcast entries by seeding the staging dir with the current
# feed; generate_appcast will merge the new release entry into it.
if [ -f "${APPCAST_PATH}" ]; then
  cp "${APPCAST_PATH}" "${STAGING_DIR}/appcast.xml"
fi

"${GENERATE_APPCAST_BIN}" \
  "${STAGING_DIR}" \
  --account "${SPARKLE_KEY_ACCOUNT}" \
  --download-url-prefix "${DOWNLOAD_URL_PREFIX}" \
  --link "${SPARKLE_SITE_URL}" \
  --full-release-notes-url "${RELEASE_NOTES_URL}" \
  --embed-release-notes \
  --maximum-deltas 0

cp "${STAGING_DIR}/appcast.xml" "${APPCAST_PATH}"

echo
echo "Updated ${APPCAST_PATH}"
echo "Verifying EdDSA signature was written…"
if grep -q 'sparkle:edSignature' "${APPCAST_PATH}"; then
  echo "  OK — sparkle:edSignature is present"
else
  echo "  MISSING — did generate_keys store the private key under account '${SPARKLE_KEY_ACCOUNT}'?" >&2
  exit 1
fi
