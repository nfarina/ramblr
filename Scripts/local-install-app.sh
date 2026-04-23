#!/usr/bin/env bash
set -euo pipefail

# Builds Ramblr in Release, then swaps it into /Applications/Ramblr.app without
# triggering macOS permission reprompts.
#
# The trick: TCC (Accessibility, Screen Recording, etc.) keys permissions to the
# app's Designated Requirement — bundle ID + Team ID. As long as the signing
# identity and bundle ID stay the same, permissions persist. The install dance
# below avoids the Finder "Replace" path which can invalidate TCC entries.

SCHEME="Ramblr"
CONFIGURATION="Release"
DERIVED_DATA_PATH="build"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${SCHEME}.app"
INSTALL_PATH="/Applications/${SCHEME}.app"

cd "$(dirname "$0")/.."

command -v trash >/dev/null 2>&1 || {
  echo "The 'trash' CLI is required. Install with: brew install trash" >&2
  exit 1
}

BUILD_CMD=(xcodebuild
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -derivedDataPath "${DERIVED_DATA_PATH}"
  build)

echo "Building ${SCHEME} (${CONFIGURATION})…"
if command -v xcbeautify >/dev/null 2>&1; then
  set -o pipefail
  "${BUILD_CMD[@]}" | xcbeautify
else
  "${BUILD_CMD[@]}"
fi

if [ ! -d "${APP_PATH}" ]; then
  echo "Built app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "Stopping any running ${SCHEME}…"
pkill -x "${SCHEME}" 2>/dev/null || true

if [ -e "${INSTALL_PATH}" ]; then
  echo "Trashing old ${INSTALL_PATH}…"
  trash "${INSTALL_PATH}"
fi

echo "Installing to ${INSTALL_PATH}…"
cp -R "${APP_PATH}" /Applications/

echo "Launching ${INSTALL_PATH}…"
open "${INSTALL_PATH}"

echo
echo "Installed:"
codesign -dv --verbose=4 "${INSTALL_PATH}" 2>&1 \
  | sed -n 's/^Identifier=/  Identifier: /p; s/^Authority=/  Authority: /p' \
  | head -n 3
