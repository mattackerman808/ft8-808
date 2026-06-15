#!/usr/bin/env bash
#
# build-hamlib.sh — build a relocatable Hamlib and package it as an
# xcframework that FT8-808 bundles, so end users never need `brew install`.
#
# Hamlib is LGPL-2.1-or-later. We build a SHARED library and link it
# dynamically (the user can replace the dylib), which keeps FT8-808's own MIT
# license unencumbered. The dylib's install name is rewritten to @rpath so it
# can live inside the app bundle's Contents/Frameworks (or be found via rpath
# during `swift run`).
#
# Run this once (or in CI). Output: Vendor/Hamlib.xcframework
# Requirements: clang (Xcode), make. (No autotools needed — release tarballs
# ship a pre-generated configure.)
#
# Usage:
#   Scripts/build-hamlib.sh                 # host arch (arm64 here)
#   ARCHS="arm64 x86_64" Scripts/build-hamlib.sh   # universal (slower)

set -euo pipefail

HAMLIB_VERSION="4.7.1"
TARBALL_URL="https://github.com/Hamlib/Hamlib/releases/download/${HAMLIB_VERSION}/hamlib-${HAMLIB_VERSION}.tar.gz"
MIN_MACOS="13.0"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/Vendor"
WORK="${REPO_ROOT}/.hamlib-build"
ARCHS="${ARCHS:-$(uname -m)}"

mkdir -p "${WORK}" "${OUT_DIR}"
cd "${WORK}"

# --- 1. Fetch + extract -------------------------------------------------------
if [[ ! -f "hamlib-${HAMLIB_VERSION}.tar.gz" ]]; then
    echo ">> Downloading Hamlib ${HAMLIB_VERSION}"
    curl -fSL "${TARBALL_URL}" -o "hamlib-${HAMLIB_VERSION}.tar.gz"
fi
echo ">> SHA256: $(shasum -a 256 "hamlib-${HAMLIB_VERSION}.tar.gz" | cut -d' ' -f1)"

rm -rf "hamlib-${HAMLIB_VERSION}"
tar xzf "hamlib-${HAMLIB_VERSION}.tar.gz"
SRC="${WORK}/hamlib-${HAMLIB_VERSION}"

# --- 2. Build per-arch --------------------------------------------------------
PER_ARCH_DYLIBS=()
HEADERS_PREFIX=""
for ARCH in ${ARCHS}; do
    echo ">> Building Hamlib for ${ARCH}"
    PREFIX="${WORK}/stage-${ARCH}"
    rm -rf "${PREFIX}"
    BUILD="${SRC}-${ARCH}"
    rm -rf "${BUILD}"; cp -R "${SRC}" "${BUILD}"

    # cp -R reorders mtimes; touch the autotools-generated files in dependency
    # order so make won't try to regenerate them (we have no autoconf/automake).
    ( cd "${BUILD}" && touch -c aclocal.m4 configure */Makefile.in Makefile.in \
        config.h.in 2>/dev/null; find . -name '*.in' -exec touch {} + ; \
        touch aclocal.m4 ; find . -name 'Makefile.in' -exec touch {} + ; \
        touch configure ; find . -name configure -exec touch {} + )

    HOST_FLAG=()
    if [[ "${ARCH}" != "$(uname -m)" ]]; then
        HOST_FLAG=(--host="${ARCH}-apple-darwin")
    fi

    ( cd "${BUILD}" && \
      ./configure \
        --prefix="${PREFIX}" \
        --disable-maintainer-mode \
        --enable-shared --disable-static \
        --without-cxx-binding \
        --without-libusb \
        "${HOST_FLAG[@]}" \
        CC="clang -arch ${ARCH}" \
        CFLAGS="-arch ${ARCH} -mmacosx-version-min=${MIN_MACOS} -O2" \
        > configure.log 2>&1 && \
      make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1 && \
      make install > install.log 2>&1 )

    DYLIB="${PREFIX}/lib/libhamlib.4.dylib"
    install_name_tool -id "@rpath/libhamlib.4.dylib" "${DYLIB}"
    PER_ARCH_DYLIBS+=("${DYLIB}")
    HEADERS_PREFIX="${PREFIX}"
done

# --- 3. Combine arches (lipo) -------------------------------------------------
UNIVERSAL="${WORK}/libhamlib.4.dylib"
if [[ ${#PER_ARCH_DYLIBS[@]} -gt 1 ]]; then
    echo ">> lipo: ${ARCHS}"
    lipo -create "${PER_ARCH_DYLIBS[@]}" -output "${UNIVERSAL}"
else
    cp "${PER_ARCH_DYLIBS[0]}" "${UNIVERSAL}"
fi
echo ">> Architectures: $(lipo -archs "${UNIVERSAL}")"

# --- 4. Refresh vendored headers (used by the CHamlib shim to compile) --------
# The shim (Sources/CHamlib) #includes <hamlib/rig.h>, so keep these in sync
# with the built version. The xcframework itself is link-only (no headers), so
# its module name can't collide with the CHamlib shim target.
VENDOR_HEADERS="${REPO_ROOT}/Sources/CHamlib/vendor/hamlib"
if [[ -d "${VENDOR_HEADERS}" ]]; then
    rm -f "${VENDOR_HEADERS}"/*.h
    cp "${HEADERS_PREFIX}/include/hamlib/"*.h "${VENDOR_HEADERS}/"
fi

# --- 5. Package xcframework (link-only: library, no headers) ------------------
rm -rf "${OUT_DIR}/Hamlib.xcframework"
xcodebuild -create-xcframework \
    -library "${UNIVERSAL}" \
    -output "${OUT_DIR}/Hamlib.xcframework" > "${WORK}/xcframework.log" 2>&1

# Preserve the license for our NOTICE obligations.
cp "${SRC}/COPYING.LIB" "${OUT_DIR}/Hamlib.LICENSE.txt" 2>/dev/null || \
cp "${SRC}/LICENSE"     "${OUT_DIR}/Hamlib.LICENSE.txt" 2>/dev/null || true

echo ">> Done: ${OUT_DIR}/Hamlib.xcframework"
