#!/bin/sh

HEADER_LINE_1="// SPDX-License-Identifier: MIT"
HEADER_LINE_2="// Copyright (c) 2026 Mercedes-Benz Group AG"

cd -P -- "$(dirname -- "$0")"
cd ..

MISSING=""
FOUND=0
TOTAL=0

SCAN_DIRS="Sources Tests"
if [ -d Examples ]; then
    SCAN_DIRS="$SCAN_DIRS Examples"
fi

# Package manifests are skipped: 'swift-tools-version' must be their first line.
for file in $(find $SCAN_DIRS -name "*.swift" -not -name "Package.swift" -not -path "*/.build/*"); do
    TOTAL=$((TOTAL + 1))
    if ! head -1 "$file" | grep -q "SPDX-License-Identifier"; then
        MISSING="${MISSING}${file}\n"
        FOUND=$((FOUND + 1))
    fi
done

if [ "$1" = "--fix" ]; then
    if [ $FOUND -eq 0 ]; then
        echo "All $TOTAL files have license headers."
        exit 0
    fi
    printf "$MISSING" | while read -r file; do
        [ -z "$file" ] && continue
        printf '%s\n%s\n\n' "$HEADER_LINE_1" "$HEADER_LINE_2" | cat - "$file" > "$file.tmp" && mv "$file.tmp" "$file"
        echo "fixed: $file"
    done
    echo "Added headers to $FOUND file(s)."
    exit 0
fi

if [ $FOUND -gt 0 ]; then
    echo "Missing SPDX license header in $FOUND file(s):"
    printf "$MISSING"
    echo "Run 'scripts/check-license-headers.sh --fix' to add them."
    exit 1
fi

echo "All $TOTAL files have license headers."
