#!/bin/sh

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

if [ "$1" = "--check" ]; then
    "$SWIFT_FORMAT" lint --strict --recursive Sources Tests
else
    "$SWIFT_FORMAT" format --in-place --recursive Sources Tests
    echo "Formatted all Swift files."
fi
