#!/usr/bin/env bash
set -euo pipefail

# Downloads Sparkle's command-line tools (generate_keys, sign_update,
# generate_appcast) into build/sparkle-tools/<version>/extracted/, then prints
# that directory path. Other scripts source this to locate the tools.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/sparkle-config.sh"

ARCHIVE_PATH="${SPARKLE_TOOLS_CACHE_DIR}/${SPARKLE_TOOLS_ARCHIVE}"
EXTRACT_DIR="${SPARKLE_TOOLS_CACHE_DIR}/extracted"

if [ ! -x "${EXTRACT_DIR}/bin/generate_appcast" ] \
   || [ ! -x "${EXTRACT_DIR}/bin/generate_keys" ] \
   || [ ! -x "${EXTRACT_DIR}/bin/sign_update" ]; then
  mkdir -p "${SPARKLE_TOOLS_CACHE_DIR}"

  if [ ! -f "${ARCHIVE_PATH}" ]; then
    command -v gh >/dev/null 2>&1 || {
      echo "The 'gh' CLI is required to download Sparkle tools. Install with: brew install gh" >&2
      exit 1
    }
    gh release download "${SPARKLE_VERSION}" \
      --repo "${SPARKLE_TOOLS_REPO}" \
      -p "${SPARKLE_TOOLS_ARCHIVE}" \
      -D "${SPARKLE_TOOLS_CACHE_DIR}" >/dev/null
  fi

  rm -rf "${EXTRACT_DIR}"
  mkdir -p "${EXTRACT_DIR}"
  tar -xf "${ARCHIVE_PATH}" -C "${EXTRACT_DIR}"
fi

printf '%s\n' "${EXTRACT_DIR}"
