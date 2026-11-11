#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

PRODUCT_BIN_NAME="PeekPane"
NATIVE_HOST_NAME="PeekPaneNativeHost"

VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo "1.0")"
UNIVERSAL=false
SKIP_TCC_RESET=false
RELEASE_BUILD=false
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

for arg in "$@"; do
    case "${arg}" in
        --release|--prod)
            RELEASE_BUILD=true
            ;;
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
            echo "Usage: ./build_app.sh [--release] [--universal] [--skip-tcc-reset] [--version=X.Y]" >&2
            exit 1
            ;;
    esac
done

if [[ "${RELEASE_BUILD}" == "true" ]]; then
    APP_NAME="PeekPane"
    BUNDLE_ID="com.peekpane.app"
    NATIVE_HOST_ID="com.peekpane.app.native-host"
    IS_DEV_BUILD=false
else
    APP_NAME="PeekPaneDev"
    BUNDLE_ID="com.peekpane.app.dev"
    NATIVE_HOST_ID="com.peekpane.app.dev.native-host"
    IS_DEV_BUILD=true
fi

APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

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
BIN_PATH="${BIN_DIR}/${PRODUCT_BIN_NAME}"
HELPER_BIN_PATH="${BIN_DIR}/${NATIVE_HOST_NAME}"

echo "==> Packaging ${APP_BUNDLE} (${BUNDLE_ID})..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${HELPERS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

cp "${HELPER_BIN_PATH}" "${HELPERS_DIR}/${NATIVE_HOST_NAME}"
chmod +x "${HELPERS_DIR}/${NATIVE_HOST_NAME}"

if [[ -d "Extension" ]]; then
    cp -R "Extension" "${RESOURCES_DIR}/Extension"
fi

if [[ -d "FirefoxExtension" ]]; then
    cp -R "FirefoxExtension" "${RESOURCES_DIR}/FirefoxExtension"
fi

if [[ -f "peekpane-firefox.xpi" ]]; then
    cp "peekpane-firefox.xpi" "${RESOURCES_DIR}/peekpane-firefox.xpi"
fi

cp "Info.plist" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${APP_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :PPIsDevBuild" "${CONTENTS_DIR}/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :PPIsDevBuild bool ${IS_DEV_BUILD}" "${CONTENTS_DIR}/Info.plist"

if [[ -f "AppIcon.svg" ]]; then
    echo "==> Generating AppIcon.icns (dev badge: ${IS_DEV_BUILD}) and browser extension icons..."
    TEMP_ICON_ROOT="$(mktemp -d)"
    ICONSET_DIR="${TEMP_ICON_ROOT}/AppIcon.iconset"
    mkdir -p "${ICONSET_DIR}"
    CLEAN_PNG="${TEMP_ICON_ROOT}/clean_1024.png"
    APP_ICON_PNG="${TEMP_ICON_ROOT}/app_1024.png"

    swift - "${CLEAN_PNG}" "${APP_ICON_PNG}" "${IS_DEV_BUILD}" <<'EOF'
import AppKit

let cleanOutputPath = CommandLine.arguments[1]
let appIconOutputPath = CommandLine.arguments[2]
let isDevBuild = CommandLine.arguments[3] == "true"

let svgURL = URL(fileURLWithPath: "AppIcon.svg")
guard let image = NSImage(contentsOf: svgURL) else { exit(1) }
let size = NSSize(width: 1024, height: 1024)

func makeBitmap() -> NSBitmapImageRep {
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
    return rep
}

let cleanRep = makeBitmap()
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: cleanRep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let cleanData = cleanRep.representation(using: .png, properties: [:]) else { exit(1) }
try cleanData.write(to: URL(fileURLWithPath: cleanOutputPath))

if !isDevBuild {
    try cleanData.write(to: URL(fileURLWithPath: appIconOutputPath))
    exit(0)
}

let devRep = makeBitmap()
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: devRep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)

// Clip strictly inside the macOS 832x832 (rx=190) squircle interior so macOS IconServices
// preserves the native Liquid Glass squircle silhouette instead of adding a white backing plate.
NSGraphicsContext.saveGraphicsState()
let squircleInteriorClip = NSBezierPath(
    roundedRect: NSRect(x: 98, y: 98, width: 828, height: 828),
    xRadius: 188,
    yRadius: 188
)
squircleInteriorClip.addClip()

let xform = NSAffineTransform()
xform.translateX(by: 774, yBy: 250)
xform.rotate(byDegrees: 45)
xform.concat()

let ribbonRect = NSRect(x: -340, y: -50, width: 680, height: 100)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: 6)
shadow.shadowBlurRadius = 18
shadow.shadowColor = NSColor(calibratedRed: 0.01, green: 0.02, blue: 0.08, alpha: 0.72)
shadow.set()
NSColor(calibratedRed: 0.96, green: 0.52, blue: 0.02, alpha: 1.0).setFill()
NSBezierPath(rect: ribbonRect).fill()
NSGraphicsContext.restoreGraphicsState()

let ribbonGradient = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 1.00, green: 0.75, blue: 0.06, alpha: 0.98), 0.0),
    (NSColor(calibratedRed: 0.98, green: 0.50, blue: 0.02, alpha: 0.98), 0.55),
    (NSColor(calibratedRed: 0.88, green: 0.32, blue: 0.04, alpha: 0.98), 1.0)
)!
ribbonGradient.draw(in: ribbonRect, angle: -90)

NSColor(calibratedWhite: 1.0, alpha: 0.55).setStroke()
let topEdge = NSBezierPath()
topEdge.move(to: NSPoint(x: -340, y: 46.5))
topEdge.line(to: NSPoint(x: 340, y: 46.5))
topEdge.lineWidth = 3.0
topEdge.stroke()

let bottomEdge = NSBezierPath()
bottomEdge.move(to: NSPoint(x: -340, y: -46.5))
bottomEdge.line(to: NSPoint(x: 340, y: -46.5))
bottomEdge.lineWidth = 3.0
bottomEdge.stroke()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let textShadow = NSShadow()
textShadow.shadowOffset = NSSize(width: 0, height: -2)
textShadow.shadowBlurRadius = 4
textShadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.38)

let font = NSFont.systemFont(ofSize: 60, weight: .black)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
    .kern: 5.0,
    .paragraphStyle: paragraph,
    .shadow: textShadow
]
let label = "DEV" as NSString
let textSize = label.size(withAttributes: attrs)
let textRect = NSRect(
    x: -200,
    y: -textSize.height * 0.5 - 1,
    width: 400,
    height: textSize.height
)
label.draw(in: textRect, withAttributes: attrs)
NSGraphicsContext.restoreGraphicsState()

// Re-stroke subtle squircle rim highlight over the clipped ribbon ends
NSColor(calibratedWhite: 1.0, alpha: 0.26).setStroke()
let rimPath = NSBezierPath(
    roundedRect: NSRect(x: 98, y: 98, width: 828, height: 828),
    xRadius: 188,
    yRadius: 188
)
rimPath.lineWidth = 4.5
rimPath.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let devData = devRep.representation(using: .png, properties: [:]) else { exit(1) }
try devData.write(to: URL(fileURLWithPath: appIconOutputPath))
EOF

    sips -z 16 16     "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
    sips -z 32 32     "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
    sips -z 32 32     "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
    sips -z 64 64     "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
    sips -z 128 128   "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
    sips -z 256 256   "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
    sips -z 512 512   "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
    cp "${APP_ICON_PNG}" "${ICONSET_DIR}/icon_512x512@2x.png"

    iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
    cp "AppIcon.svg" "${RESOURCES_DIR}/AppIcon.svg"

    EXT_SOURCE_PNG="${CLEAN_PNG}"
    if [[ -f "ExtensionIcon.svg" ]]; then
        EXT_SOURCE_PNG="${TEMP_ICON_ROOT}/ext_512.png"
        swift - "${EXT_SOURCE_PNG}" <<'EOF'
import AppKit

let outPath = CommandLine.arguments[1]
guard let svgImage = NSImage(contentsOf: URL(fileURLWithPath: "ExtensionIcon.svg")) else { exit(1) }
let size = NSSize(width: 512, height: 512)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 512,
    pixelsHigh: 512,
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
svgImage.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: outPath))
EOF
    fi

    if [[ -d "${RESOURCES_DIR}/Extension" ]]; then
        mkdir -p "${RESOURCES_DIR}/Extension/icons"
        sips -z 16 16   "${EXT_SOURCE_PNG}" --out "${TEMP_ICON_ROOT}/ext_16.png" >/dev/null
        sips -z 32 32   "${EXT_SOURCE_PNG}" --out "${TEMP_ICON_ROOT}/ext_32.png" >/dev/null
        sips -z 48 48   "${EXT_SOURCE_PNG}" --out "${TEMP_ICON_ROOT}/ext_48.png" >/dev/null
        sips -z 128 128 "${EXT_SOURCE_PNG}" --out "${TEMP_ICON_ROOT}/ext_128.png" >/dev/null
        cp "${TEMP_ICON_ROOT}/ext_16.png"  "${RESOURCES_DIR}/Extension/icons/icon-16.png"
        cp "${TEMP_ICON_ROOT}/ext_32.png"  "${RESOURCES_DIR}/Extension/icons/icon-32.png"
        cp "${TEMP_ICON_ROOT}/ext_48.png"  "${RESOURCES_DIR}/Extension/icons/icon-48.png"
        cp "${TEMP_ICON_ROOT}/ext_128.png" "${RESOURCES_DIR}/Extension/icons/icon-128.png"
        if [[ -d "${RESOURCES_DIR}/FirefoxExtension" ]]; then
            mkdir -p "${RESOURCES_DIR}/FirefoxExtension/icons"
            cp "${TEMP_ICON_ROOT}/ext_16.png"  "${RESOURCES_DIR}/FirefoxExtension/icons/icon-16.png"
            cp "${TEMP_ICON_ROOT}/ext_32.png"  "${RESOURCES_DIR}/FirefoxExtension/icons/icon-32.png"
            cp "${TEMP_ICON_ROOT}/ext_48.png"  "${RESOURCES_DIR}/FirefoxExtension/icons/icon-48.png"
            cp "${TEMP_ICON_ROOT}/ext_128.png" "${RESOURCES_DIR}/FirefoxExtension/icons/icon-128.png"
        fi
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

touch "${APP_BUNDLE}"
echo "==> Built ${APP_BUNDLE} (v${VERSION}) at ${ROOT_DIR}/${APP_BUNDLE}"
