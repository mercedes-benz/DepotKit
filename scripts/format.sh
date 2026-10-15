#!/bin/sh

# Formats (or, with --check, lints) the package sources, tests, and example sources.

set -eu

cd -P -- "$(dirname -- "$0")"
cd ..

if which swift-format > /dev/null 2>&1; then
    SWIFT_FORMAT="swift-format"
elif xcrun --find swift-format > /dev/null 2>&1; then
    SWIFT_FORMAT="$(xcrun --find swift-format)"
else
    echo "swift-format not found. It ships with Xcode 26+ / Swift 6.2+."
    exit 1
fi

if [ "${1:-}" = "--check" ]; then
    "$SWIFT_FORMAT" lint --strict --recursive Sources Tests Examples
else
    "$SWIFT_FORMAT" format --in-place --recursive Sources Tests Examples
    echo "Formatted all Swift files."
fi
