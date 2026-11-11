#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

RUN_ANALYZE=false
for arg in "$@"; do
    case "$arg" in
        --analyze) RUN_ANALYZE=true ;;
        -h | --help)
            echo "Usage: ./lint.sh [--analyze]"
            echo "  --analyze  Also run 'swiftlint analyze' (unused_import / unused_declaration)."
            echo "             Requires a clean verbose build (~40s)."
            exit 0
            ;;
        *)
            echo "error: unknown argument '$arg' (see ./lint.sh --help)" >&2
            exit 1
            ;;
    esac
done

echo "==> Running swift-format linter (strict mode)..."
swift format lint --strict --configuration .swift-format --recursive Sources Tests Package.swift

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "error: swiftlint is not installed. Install it with 'brew install swiftlint' and re-run." >&2
    exit 1
fi

echo "==> Running SwiftLint (strict mode, $(swiftlint version))..."
swiftlint lint --strict --config .swiftlint.yml

if [[ "${RUN_ANALYZE}" == "true" ]]; then
    # Analyzer rules need the full compiler invocations, so build from a fresh scratch path
    # (an incremental build would skip compile commands and silently analyze nothing).
    ANALYZE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/peekpane-analyze.XXXXXX")"
    trap 'rm -rf "${ANALYZE_DIR}"' EXIT
    COMPILER_LOG="${ANALYZE_DIR}/build.log"

    echo "==> Building with verbose compiler log for SwiftLint analyze..."
    if ! swift build --scratch-path "${ANALYZE_DIR}/build" -v >"${COMPILER_LOG}" 2>&1; then
        tail -50 "${COMPILER_LOG}" >&2
        echo "error: build failed; cannot run swiftlint analyze." >&2
        exit 1
    fi

    if ! grep -q "swift-frontend.*-module-name PeekPane" "${COMPILER_LOG}"; then
        echo "error: no PeekPane compiler invocations found in build log; analyze would be a no-op." >&2
        exit 1
    fi

    echo "==> Running SwiftLint analyze (strict mode)..."
    swiftlint analyze --strict --config .swiftlint.yml --compiler-log-path "${COMPILER_LOG}"
fi

echo "==> All lint checks passed with 0 warnings!"
