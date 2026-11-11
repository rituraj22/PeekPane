#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

APP_NAME="PeekPane"
BUNDLE_ID="com.peekpane.app"
NATIVE_HOST_NAME="PeekPaneNativeHost"
NATIVE_HOST_ID="com.peekpane.app.native-host"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo "1.0")"
UNIVERSAL=false
SKIP_TCC_RESET=false
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

for arg in "$@"; do
    case "${arg}" in
        --universal)
            UNIVERSAL=true
            ;;
        --skip-tcc-reset)
            SKIP_TCC_RESET=true
            ;;
        --version=*)
            VERSION="${arg#*=}"
            ;;
        *)
            echo "Unknown option: ${arg}" >&2
            echo "Usage: ./build_app.sh [--universal] [--skip-tcc-reset] [--version=X.Y]" >&2
            exit 1
            ;;
    esac
done

if [[ "${CI:-false}" == "true" ]]; then
    SKIP_TCC_RESET=true
fi

BUILD_FLAGS=(-c release)
if [[ "${UNIVERSAL}" == "true" ]]; then
    echo "==> Building ${APP_NAME} & ${NATIVE_HOST_NAME} v${VERSION} (Universal: arm64 + x86_64)..."
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
else
    echo "==> Building ${APP_NAME} & ${NATIVE_HOST_NAME} v${VERSION} (Native architecture)..."
fi

swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"
HELPER_BIN_PATH="${BIN_DIR}/${NATIVE_HOST_NAME}"

echo "==> Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${HELPERS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

cp "${HELPER_BIN_PATH}" "${HELPERS_DIR}/${NATIVE_HOST_NAME}"
chmod +x "${HELPERS_DIR}/${NATIVE_HOST_NAME}"

if [[ -d "Extension" ]]; then
    cp -R "Extension" "${RESOURCES_DIR}/Extension"
fi

cp "Info.plist" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${CONTENTS_DIR}/Info.plist"

if [[ -f "AppIcon.svg" ]]; then
    echo "==> Generating AppIcon.icns and browser extension icons from AppIcon.svg..."
    TEMP_ICON_ROOT="$(mktemp -d)"
    ICONSET_DIR="${TEMP_ICON_ROOT}/AppIcon.iconset"
    mkdir -p "${ICONSET_DIR}"
    BASE_PNG="${TEMP_ICON_ROOT}/base_1024.png"

    swift - "${BASE_PNG}" <<'EOF'
import AppKit

let outputPath = CommandLine.arguments[1]
let svgURL = URL(fileURLWithPath: "AppIcon.svg")
guard let image = NSImage(contentsOf: svgURL) else { exit(1) }
let size = NSSize(width: 1024, height: 1024)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024,
    pixelsHigh: 1024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }

rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else { exit(1) }
try pngData.write(to: URL(fileURLWithPath: outputPath))
EOF

    sips -z 16 16     "${BASE_PNG}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
    sips -z 32 32     "${BASE_PNG}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
    sips -z 32 32     "${BASE_PNG}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
    sips -z 64 64     "${BASE_PNG}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
    sips -z 128 128   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
    sips -z 256 256   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
    sips -z 512 512   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
    cp "${BASE_PNG}" "${ICONSET_DIR}/icon_512x512@2x.png"

    iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
    cp "AppIcon.svg" "${RESOURCES_DIR}/AppIcon.svg"

    if [[ -d "${RESOURCES_DIR}/Extension" ]]; then
        mkdir -p "${RESOURCES_DIR}/Extension/icons"
        sips -z 16 16   "${BASE_PNG}" --out "${TEMP_ICON_ROOT}/ext_16.png" >/dev/null
        sips -z 48 48   "${BASE_PNG}" --out "${TEMP_ICON_ROOT}/ext_48.png" >/dev/null
        sips -z 128 128 "${BASE_PNG}" --out "${TEMP_ICON_ROOT}/ext_128.png" >/dev/null
        cp "${TEMP_ICON_ROOT}/ext_16.png"  "${RESOURCES_DIR}/Extension/icons/icon-16.png"
        cp "${TEMP_ICON_ROOT}/ext_48.png"  "${RESOURCES_DIR}/Extension/icons/icon-48.png"
        cp "${TEMP_ICON_ROOT}/ext_128.png" "${RESOURCES_DIR}/Extension/icons/icon-128.png"
    fi

    rm -rf "${TEMP_ICON_ROOT}"
fi

echo "==> Signing nested helper ${NATIVE_HOST_NAME} (identity: ${CODESIGN_IDENTITY})..."
HELPER_CODESIGN_ARGS=(--force --sign "${CODESIGN_IDENTITY}" --identifier "${NATIVE_HOST_ID}")
if [[ "${CODESIGN_IDENTITY}" != "-" ]]; then
    HELPER_CODESIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${HELPER_CODESIGN_ARGS[@]}" "${HELPERS_DIR}/${NATIVE_HOST_NAME}"

echo "==> Signing ${APP_BUNDLE} inside-out without --deep (identity: ${CODESIGN_IDENTITY})..."
CODESIGN_ARGS=(--force --sign "${CODESIGN_IDENTITY}" --identifier "${BUNDLE_ID}")
if [[ -f "Entitlements.plist" ]]; then
    CODESIGN_ARGS+=(--entitlements "Entitlements.plist")
fi
if [[ "${CODESIGN_IDENTITY}" != "-" ]]; then
    CODESIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${CODESIGN_ARGS[@]}" "${APP_BUNDLE}"

if [[ "${SKIP_TCC_RESET}" == "false" && "${CODESIGN_IDENTITY}" == "-" ]]; then
    echo "==> Resetting stale ad-hoc TCC cache for ${BUNDLE_ID}..."
    tccutil reset ScreenCapture "${BUNDLE_ID}" >/dev/null 2>&1 || true
    tccutil reset Accessibility "${BUNDLE_ID}" >/dev/null 2>&1 || true
fi

echo "==> Built ${APP_BUNDLE} (v${VERSION}) at ${ROOT_DIR}/${APP_BUNDLE}"
