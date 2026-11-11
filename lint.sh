#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

echo "==> Running swift-format linter (strict mode)..."
swift format lint --strict --configuration .swift-format --recursive Sources Package.swift

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "error: swiftlint is not installed. Install it with 'brew install swiftlint' and re-run." >&2
    exit 1
fi

echo "==> Running SwiftLint (strict mode, $(swiftlint version))..."
swiftlint lint --strict --config .swiftlint.yml

echo "==> All lint checks passed with 0 warnings!"
