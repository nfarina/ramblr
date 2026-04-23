#!/usr/bin/env bash
set -euo pipefail

# Usage: ./Scripts/bump-project-version.sh <marketing-version>
#
# Writes MARKETING_VERSION = <arg> into every build configuration in
# Ramblr.xcodeproj/project.pbxproj and increments CURRENT_PROJECT_VERSION by
# one. Sparkle uses CFBundleShortVersionString (MARKETING_VERSION) for
# semver-style comparison and CFBundleVersion (CURRENT_PROJECT_VERSION) as a
# monotonic tiebreaker, so both need to advance every release.
#
# Prints the new build number on success.

if [ $# -ne 1 ]; then
  echo "Usage: $0 <marketing-version>" >&2
  exit 1
fi

NEW_VERSION="${1#v}"
PBXPROJ="$(cd "$(dirname "$0")/.." && pwd)/Ramblr.xcodeproj/project.pbxproj"

if [ ! -f "${PBXPROJ}" ]; then
  echo "project.pbxproj not found at ${PBXPROJ}" >&2
  exit 1
fi

if ! [[ "${NEW_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}([-+][A-Za-z0-9.-]+)?$ ]]; then
  echo "Version '${NEW_VERSION}' doesn't look like semver (e.g. 1.2.3)" >&2
  exit 1
fi

CURRENT_BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\);.*/\1/p' "${PBXPROJ}" | sort -n | tail -n 1)"
if [ -z "${CURRENT_BUILD}" ]; then
  echo "Could not read CURRENT_PROJECT_VERSION from project.pbxproj" >&2
  exit 1
fi
NEW_BUILD=$((CURRENT_BUILD + 1))

# BSD sed (macOS) requires the empty-string extension arg; we rewrite in place.
sed -i '' \
  -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${NEW_VERSION};/g" \
  -e "s/CURRENT_PROJECT_VERSION = [0-9][0-9]*;/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" \
  "${PBXPROJ}"

# Sanity check the edits landed.
if ! grep -q "MARKETING_VERSION = ${NEW_VERSION};" "${PBXPROJ}"; then
  echo "Failed to update MARKETING_VERSION" >&2
  exit 1
fi
if ! grep -q "CURRENT_PROJECT_VERSION = ${NEW_BUILD};" "${PBXPROJ}"; then
  echo "Failed to update CURRENT_PROJECT_VERSION" >&2
  exit 1
fi

echo "Bumped MARKETING_VERSION → ${NEW_VERSION}"
echo "Bumped CURRENT_PROJECT_VERSION → ${NEW_BUILD} (was ${CURRENT_BUILD})"
printf '%s\n' "${NEW_BUILD}"
