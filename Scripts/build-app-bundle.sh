#!/usr/bin/env bash
#
# build-app-bundle.sh — assemble FT8-808.app from a built ft8gui executable and
# the bundled Hamlib dylib, ready to install in /Applications. Optionally signs
# it (Developer ID + hardened runtime) when an identity is given.
#
# The dylib lives in Contents/Frameworks and is found via an
# @executable_path/../Frameworks rpath added to the executable (its install name
# is already @rpath/libhamlib.4.dylib).
#
# Usage:
#   Scripts/build-app-bundle.sh <ft8gui-bin> <libhamlib.dylib> <version> <out-dir> [signing-identity]
#
# With no signing identity the bundle is left unsigned (ad-hoc sign it for local
# runs:  codesign --force --deep -s - <app> ).

set -euo pipefail

BIN="${1:?ft8gui binary path}"
DYLIB="${2:?libhamlib dylib path}"
VERSION="${3:?version}"
OUT_DIR="${4:?output dir}"
SIGN_ID="${5:-}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_SRC="${REPO_ROOT}/Sources/ft8gui/Info.plist"
ICON_SRC="${REPO_ROOT}/Sources/ft8gui/AppIcon.icns"
ENTITLEMENTS="${REPO_ROOT}/Scripts/ft8gui.entitlements"
PB=/usr/libexec/PlistBuddy

APP="${OUT_DIR}/FT8-808.app"
EXEC_NAME="FT8-808"

echo ">> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Frameworks" "${APP}/Contents/Resources"

# Executable + embedded dylib.
cp "${BIN}" "${APP}/Contents/MacOS/${EXEC_NAME}"
chmod +x "${APP}/Contents/MacOS/${EXEC_NAME}"
cp "${DYLIB}" "${APP}/Contents/Frameworks/libhamlib.4.dylib"
install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP}/Contents/MacOS/${EXEC_NAME}"

# Icon.
[ -f "${ICON_SRC}" ] && cp "${ICON_SRC}" "${APP}/Contents/Resources/AppIcon.icns"

# Info.plist: start from the source, add the bundle-only keys.
PLIST="${APP}/Contents/Info.plist"
cp "${PLIST_SRC}" "${PLIST}"
add_or_set() {  # key type value
    "$PB" -c "Add :$1 $2 $3" "${PLIST}" 2>/dev/null || "$PB" -c "Set :$1 $3" "${PLIST}"
}
add_or_set CFBundleExecutable        string "${EXEC_NAME}"
add_or_set CFBundlePackageType       string "APPL"
add_or_set CFBundleInfoDictionaryVersion string "6.0"
add_or_set CFBundleShortVersionString string "${VERSION}"
add_or_set CFBundleVersion           string "${VERSION}"
add_or_set LSMinimumSystemVersion    string "13.0"
add_or_set LSApplicationCategoryType string "public.app-category.utilities"
[ -f "${ICON_SRC}" ] && add_or_set CFBundleIconFile string "AppIcon"

# Optional signing (dylib first — library validation needs same-team signing —
# then the bundle, which seals the signed dylib; no --deep needed).
if [ -n "${SIGN_ID}" ]; then
    echo ">> Signing with: ${SIGN_ID}"
    codesign --force --options runtime --timestamp \
        --sign "${SIGN_ID}" "${APP}/Contents/Frameworks/libhamlib.4.dylib"
    codesign --force --options runtime --timestamp \
        --entitlements "${ENTITLEMENTS}" \
        --sign "${SIGN_ID}" "${APP}"
    codesign --verify --strict --verbose=2 "${APP}"
fi

echo ">> Done: ${APP}"
