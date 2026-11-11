#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

APP_NAME="PeekPane"
APP_BUNDLE="${APP_NAME}.app"
VERSION="${1:-$(tr -d '[:space:]' < VERSION 2>/dev/null || echo "1.0")}"
VERSION="${VERSION#v}"
DIST_DIR="${ROOT_DIR}/dist"

ZIP_NAME="${APP_NAME}-${VERSION}-macos.zip"
DMG_NAME="${APP_NAME}-${VERSION}-macos.dmg"
ZIP_PATH="${DIST_DIR}/${ZIP_NAME}"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
CHECKSUMS_PATH="${DIST_DIR}/SHA256SUMS.txt"

echo "==> Running strict linter..."
./lint.sh

echo "==> Running unit tests..."
swift test

echo "==> Building Universal Release ${APP_BUNDLE} (v${VERSION})..."
./build_app.sh --universal --skip-tcc-reset --version="${VERSION}"

echo "==> Creating release artifacts in ${DIST_DIR}..."
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

echo "==> Creating ${ZIP_NAME} via ditto..."
ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

echo "==> Creating ${DMG_NAME}..."
DMG_STAGING="$(mktemp -d)"
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/${APP_BUNDLE}"
ln -s /Applications "${DMG_STAGING}/Applications"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null
rm -rf "${DMG_STAGING}"

echo "==> Computing SHA-256 checksums..."
(
    cd "${DIST_DIR}"
    shasum -a 256 "${ZIP_NAME}" "${DMG_NAME}" > "${CHECKSUMS_PATH}"
)

ZIP_SHA256="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"

if [[ -f "Casks/peekpane.rb" ]]; then
    echo "==> Updating Casks/peekpane.rb with version ${VERSION} and sha256 ${ZIP_SHA256}..."
    sed -i '' -E "s/version \"[^\"]+\"/version \"${VERSION}\"/" Casks/peekpane.rb
    sed -i '' -E "s/sha256 \"[^\"]+\"/sha256 \"${ZIP_SHA256}\"/" Casks/peekpane.rb
fi

echo ""
echo "==> Release artifacts ready:"
cat "${CHECKSUMS_PATH}"
