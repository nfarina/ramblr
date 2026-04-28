#!/usr/bin/env bash
set -euo pipefail

# Builds Ramblr in Release, signs with Developer ID (same identity as released
# builds), and swaps it into /Applications/Ramblr.app. Uses the same signing
# chain as publish-release.sh so local and released builds share a Designated
# Requirement — meaning TCC permissions (Accessibility, etc.) persist across
# both rebuilds and cutovers to published updates.

SCHEME="Ramblr"
CONFIGURATION="Release"
DERIVED_DATA_PATH="build"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${SCHEME}.app"
INSTALL_PATH="/Applications/${SCHEME}.app"
ENTITLEMENTS_PATH="Scripts/distribution-entitlements.plist"

cd "$(dirname "$0")/.."

command -v trash >/dev/null 2>&1 || {
  echo "The 'trash' CLI is required. Install with: brew install trash" >&2
  exit 1
}

SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
if [ -z "${SIGNING_IDENTITY}" ]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
    | head -n 1)"
fi
if [ -z "${SIGNING_IDENTITY}" ]; then
  echo "No Developer ID Application identity found in the keychain." >&2
  echo "Add one via Xcode → Settings → Accounts → Manage Certificates." >&2
  exit 1
fi
echo "Signing identity: ${SIGNING_IDENTITY}"

remove_signature_if_present() {
  local target="$1"
  if codesign --display --verbose=1 "${target}" >/dev/null 2>&1; then
    codesign --remove-signature "${target}"
  fi
}

sign_with_runtime() {
  local target="$1"
  remove_signature_if_present "${target}"
  codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${target}"
}

sign_sparkle_support_binaries() {
  local app_bundle_path="$1"
  local framework_path="${app_bundle_path}/Contents/Frameworks/Sparkle.framework"
  local version_path="${framework_path}/Versions/B"
  [ -d "${framework_path}" ] || return 0

  local updater_app="${version_path}/Updater.app"
  local downloader_xpc="${version_path}/XPCServices/Downloader.xpc"
  local installer_xpc="${version_path}/XPCServices/Installer.xpc"
  local autoupdate_binary="${version_path}/Autoupdate"

  [ -e "${autoupdate_binary}" ] && sign_with_runtime "${autoupdate_binary}"
  for nested_bundle in "${downloader_xpc}" "${installer_xpc}" "${updater_app}"; do
    [ -d "${nested_bundle}" ] && sign_with_runtime "${nested_bundle}"
  done
  sign_with_runtime "${version_path}"
  sign_with_runtime "${framework_path}"
}

sign_bundled_media_adapter() {
  local app_bundle_path="$1"
  local adapter_path="${app_bundle_path}/Contents/Resources/MediaRemoteAdapter.dylib"

  if [ ! -f "${adapter_path}" ]; then
    echo "MediaRemoteAdapter.dylib not found inside the app bundle." >&2
    echo "Install media-control before building Ramblr: brew install media-control" >&2
    exit 1
  fi

  sign_with_runtime "${adapter_path}"
}

BUILD_CMD=(xcodebuild
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -derivedDataPath "${DERIVED_DATA_PATH}"
  CODE_SIGN_STYLE=Manual
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO
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

echo "Signing with Developer ID…"
sign_sparkle_support_binaries "${APP_PATH}"
sign_bundled_media_adapter "${APP_PATH}"

APP_EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${SCHEME}"
remove_signature_if_present "${APP_EXECUTABLE_PATH}"
codesign --force --options runtime --timestamp \
  --entitlements "${ENTITLEMENTS_PATH}" \
  --sign "${SIGNING_IDENTITY}" "${APP_EXECUTABLE_PATH}"

remove_signature_if_present "${APP_PATH}"
codesign --force --options runtime --timestamp \
  --entitlements "${ENTITLEMENTS_PATH}" \
  --sign "${SIGNING_IDENTITY}" "${APP_PATH}"

codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null

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
