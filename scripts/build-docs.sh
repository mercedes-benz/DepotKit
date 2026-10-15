#!/bin/bash

# Builds the DocC documentation for every library product and writes a static website to `docs/`.
#
# The DepotKit, DepotKitCombine, and DepotKitObservation archives are merged into one combined
# archive so the site serves all modules under a single hosting base path:
#
#   <base path>/documentation/                     combined landing page
#   <base path>/documentation/depotkit/            core module
#   <base path>/documentation/depotkitcombine/     Combine adapters
#   <base path>/documentation/depotkitobservation/ SwiftUI adapters
#
# The individual archives are copied to `docs/archives/`.
#
# Environment:
#   HOSTING_BASE_PATH   Base path of the hosted site (default: /DepotKit)
#   DERIVED_DATA_PATH   Derived data directory for xcodebuild (default: .build/docbuild).
#                       The directory is reused between runs and never deleted by this script.

set -euo pipefail

SCHEMES=("DepotKit" "DepotKitCombine" "DepotKitObservation")
HOSTING_BASE_PATH="${HOSTING_BASE_PATH:-/DepotKit}"
DESTINATION="generic/platform=iOS"
SITE_DIR="docs"

cd -P -- "$(dirname -- "$0")/.."

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.build/docbuild}"
PRODUCTS_DIR="${DERIVED_DATA_PATH}/Build/Products/Debug-iphoneos"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/depotkit-docs.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

DOCC="$(xcrun --find docc)"
ARCHIVES=()

for SCHEME in "${SCHEMES[@]}"; do
    echo "Building the documentation archive for $SCHEME"
    rm -rf "${PRODUCTS_DIR:?}/${SCHEME}.doccarchive"
    xcodebuild docbuild \
        -workspace . \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -skipPackagePluginValidation \
        -skipMacroValidation

    ARCHIVE="${PRODUCTS_DIR}/${SCHEME}.doccarchive"
    if [ ! -d "$ARCHIVE" ]; then
        echo "error: documentation archive not found at $ARCHIVE" >&2
        exit 1
    fi

    cp -R "$ARCHIVE" "$WORK_DIR/"
    ARCHIVES+=("$WORK_DIR/${SCHEME}.doccarchive")
done

echo "Merging documentation archives"
"$DOCC" merge "${ARCHIVES[@]}" \
    --synthesized-landing-page-name "DepotKit" \
    --output-path "$WORK_DIR/Combined.doccarchive"

echo "Building static documentation"
"$DOCC" process-archive transform-for-static-hosting "$WORK_DIR/Combined.doccarchive" \
    --hosting-base-path "$HOSTING_BASE_PATH" \
    --output-path "$WORK_DIR/site"

mkdir -p "$WORK_DIR/site/archives"
for ARCHIVE in "${ARCHIVES[@]}"; do
    cp -R "$ARCHIVE" "$WORK_DIR/site/archives/"
done

rm -rf "$SITE_DIR"
mv "$WORK_DIR/site" "$SITE_DIR"

echo "Documentation written to $SITE_DIR/"
