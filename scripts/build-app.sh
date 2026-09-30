#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RELEASE=false
OUTPUT_DIR="${PROJECT_ROOT}/target"

usage() {
    echo "Usage: $0 [--release] [--output <dir>]"
    echo ""
    echo "Options:"
    echo "  --release        Build in release mode"
    echo "  --output <dir>   Output directory (default: target/)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --release)
            RELEASE=true
            shift
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

source "${SCRIPT_DIR}/sdk-env.sh"

if [[ "$RELEASE" == true ]]; then
    CONFIGURATION="release"
else
    CONFIGURATION="debug"
fi

echo "Building sake (${CONFIGURATION})..."
swift build --configuration "${CONFIGURATION}" --package-path "${PROJECT_ROOT}"
BUILD_DIR="$(swift build --configuration "${CONFIGURATION}" --package-path "${PROJECT_ROOT}" --show-bin-path)"

VERSION="$(cat "${PROJECT_ROOT}/VERSION")"
echo "Version: ${VERSION}"

APP_NAME="Sake.app"
APP_DIR="${OUTPUT_DIR}/${APP_NAME}"

echo "Creating ${APP_NAME}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/sake" "${APP_DIR}/Contents/MacOS/"

# Wine cannot be built without these, so an app without them is an app that gets as far as
# the Play button and stops. They are copied rather than carried as a SwiftPM resource
# because they are LGPL-2.1-or-later and not MIT, which a directory named patches/ at the
# top of the repository says and Sources/SakeKit/Resources would hide.
cp -R "${PROJECT_ROOT}/patches" "${APP_DIR}/Contents/Resources/"

# The GDK runtime's source, which setup compiles with the engine's own compiler. It is C++
# with a Makefile of its own, not something SwiftPM builds.
cp -R "${PROJECT_ROOT}/xgameruntime" "${APP_DIR}/Contents/Resources/"

cp "${PROJECT_ROOT}/assets/Sake.icns" "${APP_DIR}/Contents/Resources/"

sed "s/VERSION_PLACEHOLDER/${VERSION}/g" "${PROJECT_ROOT}/Info.plist.template" > "${APP_DIR}/Contents/Info.plist"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
echo "Signing ${APP_NAME} with identity: ${CODESIGN_IDENTITY}"
codesign --force --deep -s "$CODESIGN_IDENTITY" "${APP_DIR}"

echo "Created: ${APP_DIR}"

if [[ "$RELEASE" == true ]]; then
    ARCH_SUFFIX="-$(uname -m)"
    ZIP_NAME="Sake${ARCH_SUFFIX}-${VERSION}.zip"
    echo "Creating ${ZIP_NAME}..."
    (cd "${OUTPUT_DIR}" && zip -qr "${ZIP_NAME}" "${APP_NAME}")
    echo "Created: ${OUTPUT_DIR}/${ZIP_NAME}"
fi

echo "Done!"
