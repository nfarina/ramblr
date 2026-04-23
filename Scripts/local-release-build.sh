#!/usr/bin/env bash
set -euo pipefail

# Builds Ramblr in Release, signs with Developer ID (including Sparkle's nested
# frameworks and XPC services), zips, notarizes, and staples.
#
# Usage:
#   ./Scripts/local-release-build.sh <version> [--skip-notarize]
#
# Requires:
#   - Developer ID Application cert in the login keychain
#   - A stored notarytool profile (see README: xcrun notarytool store-credentials)
#
# Override defaults via environment or .env.release.local:
#   APPLE_SIGNING_IDENTITY  Developer ID identity name (auto-detected if unset)
#   APPLE_TEAM_ID           Developer ID team ID (auto-detected from identity)
#   NOTARY_PROFILE          notarytool keychain profile name (default: ramblr-notary)

RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-.env.release.local}"
if [ -f "${RELEASE_ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${RELEASE_ENV_FILE}"
  set +a
fi

SCHEME="Ramblr"
CONFIGURATION="Release"
DERIVED_DATA_PATH="build"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${SCHEME}.app"
ENTITLEMENTS_PATH="Scripts/distribution-entitlements.plist"
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ramblr-notary}"
SKIP_NOTARIZE="false"
VERSION=""

cd "$(dirname "$0")/.."

usage() {
  cat <<EOF
Usage: ./Scripts/local-release-build.sh <version> [--skip-notarize]

<version>         e.g. 1.2.3 or v1.2.3 (used to name the output zip)
--skip-notarize   Sign only; useful for iterating before spending a notarization round-trip
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)
      if [ -z "${VERSION}" ]; then
        VERSION="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [ -z "${VERSION}" ]; then
  echo "A version is required." >&2
  usage
  exit 1
fi

VERSION="${VERSION#v}"
ZIP_PATH="dist/Ramblr-${VERSION}-macos.zip"

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

if [ -z "${DEVELOPMENT_TEAM}" ]; then
  DEVELOPMENT_TEAM="$(sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p' <<<"${SIGNING_IDENTITY}")"
fi

echo "Signing identity: ${SIGNING_IDENTITY}"
echo "Team:             ${DEVELOPMENT_TEAM}"

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

# Sparkle ships signed by the Sparkle project. When we re-sign the wrapping app
# bundle with our own Developer ID, Sparkle's nested Updater.app and XPC
# services must also be re-signed with the same identity and hardened runtime,
# working inside-out so the outer bundles' signatures cover the inner ones.
sign_sparkle_support_binaries() {
  local app_bundle_path="$1"
  local framework_path="${app_bundle_path}/Contents/Frameworks/Sparkle.framework"
  local version_path="${framework_path}/Versions/B"

  if [ ! -d "${framework_path}" ]; then
    echo "Sparkle.framework not found inside the app bundle — is Sparkle linked to the target?" >&2
    exit 1
  fi

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

mkdir -p dist
rm -f "${ZIP_PATH}"

# Stamp the version into the project so Sparkle sees matching CFBundle* values
# in the built app. The bump is intentional state; publish-release.sh commits
# it as part of the release commit.
echo "Stamping project version ${VERSION}…"
./Scripts/bump-project-version.sh "${VERSION}"

echo "Building ${SCHEME} (${CONFIGURATION})…"
BUILD_CMD=(xcodebuild
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -derivedDataPath "${DERIVED_DATA_PATH}"
  CODE_SIGN_STYLE=Manual
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO
  build)

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

echo "Signing distribution artifacts…"
sign_sparkle_support_binaries "${APP_PATH}"

APP_EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${SCHEME}"
remove_signature_if_present "${APP_EXECUTABLE_PATH}"
codesign --force --options runtime --timestamp \
  --entitlements "${ENTITLEMENTS_PATH}" \
  --sign "${SIGNING_IDENTITY}" "${APP_EXECUTABLE_PATH}"

remove_signature_if_present "${APP_PATH}"
codesign --force --options runtime --timestamp \
  --entitlements "${ENTITLEMENTS_PATH}" \
  --sign "${SIGNING_IDENTITY}" "${APP_PATH}"

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "Zipping to ${ZIP_PATH}…"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

if [ "${SKIP_NOTARIZE}" = "true" ]; then
  echo "Skipping notarization (per --skip-notarize)."
  echo "Built: ${ZIP_PATH}"
  exit 0
fi

echo "Submitting to notarytool (profile: ${NOTARY_PROFILE})…"
xcrun notarytool submit "${ZIP_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait

# Stapling an app bundle embeds the notarization ticket, then we re-zip so the
# downloadable artifact carries the ticket. Sparkle checks the ticket before
# installing — un-stapled archives will fail first-launch Gatekeeper checks on
# some network conditions.
echo "Stapling ticket to app bundle…"
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

echo "Re-zipping stapled bundle…"
rm -f "${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo
echo "Done. Artifact ready for upload and appcast generation:"
echo "  ${ZIP_PATH}"
