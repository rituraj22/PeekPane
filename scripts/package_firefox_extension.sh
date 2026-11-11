#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

EXT_DIR="${ROOT_DIR}/FirefoxExtension"
DIST_DIR="${ROOT_DIR}/dist"
ARTIFACTS_DIR="${DIST_DIR}/firefox-artifacts"
ZIP_OUT="${DIST_DIR}/peekpane-firefox-extension.zip"
XPI_DEST="${ROOT_DIR}/peekpane-firefox.xpi"

MODE="zip"
CHANNEL="unlisted"

for arg in "$@"; do
    case "${arg}" in
        --sign)
            MODE="sign"
            ;;
        --channel=*)
            CHANNEL="${arg#*=}"
            ;;
        *)
            echo "Unknown option: ${arg}" >&2
            echo "Usage: ./scripts/package_firefox_extension.sh [--sign] [--channel=unlisted|listed]" >&2
            exit 1
            ;;
    esac
done

echo "==> Validating FirefoxExtension JavaScript & manifest.json..."
node --check "${EXT_DIR}/background.js"
node --check "${EXT_DIR}/crop-overlay.js"
python3 - "${EXT_DIR}/manifest.json" <<'PY'
import json, os, sys
manifest_path = sys.argv[1]
m = json.load(open(manifest_path))
for icon_rel in m.get("icons", {}).values():
    p = os.path.join(os.path.dirname(manifest_path), icon_rel)
    assert os.path.isfile(p), f"Missing icon file: {p}"
gecko_id = m["browser_specific_settings"]["gecko"]["id"]
print(f"Validated {m['name']} v{m['version']} ({gecko_id})")
PY

mkdir -p "${DIST_DIR}"
rm -f "${ZIP_OUT}"

echo "==> Packaging clean submission archive at ${ZIP_OUT}..."
(
    cd "${EXT_DIR}"
    zip -r -X "${ZIP_OUT}" manifest.json background.js crop-overlay.js icons -x "*.DS_Store" >/dev/null
)
echo "==> Created ${ZIP_OUT}"

if [[ "${MODE}" == "sign" ]]; then
    if [[ -z "${AMO_JWT_ISSUER:-}" || -z "${AMO_JWT_SECRET:-}" ]]; then
        echo "" >&2
        echo "Error: AMO_JWT_ISSUER and AMO_JWT_SECRET environment variables are required for --sign." >&2
        echo "1. Generate free API keys at: https://addons.mozilla.org/en-US/developers/addon/api/key/" >&2
        echo "2. Run:" >&2
        echo "   AMO_JWT_ISSUER=\"user:...\" AMO_JWT_SECRET=\"...\" make firefox-sign" >&2
        exit 1
    fi

    rm -rf "${ARTIFACTS_DIR}"
    mkdir -p "${ARTIFACTS_DIR}"

    echo "==> Signing add-on via Mozilla AMO (channel: ${CHANNEL})..."
    npx --yes web-ext sign \
        --source-dir="${EXT_DIR}" \
        --artifacts-dir="${ARTIFACTS_DIR}" \
        --channel="${CHANNEL}" \
        --api-key="${AMO_JWT_ISSUER}" \
        --api-secret="${AMO_JWT_SECRET}"

    SIGNED_XPI="$(find "${ARTIFACTS_DIR}" -name "*.xpi" -print -quit)"
    if [[ -n "${SIGNED_XPI}" && -f "${SIGNED_XPI}" ]]; then
        cp "${SIGNED_XPI}" "${XPI_DEST}"
        echo "==> Copied signed .xpi to ${XPI_DEST} (will be bundled automatically by build_app.sh / make release!)"
    fi
fi
