#!/bin/sh

SCHEMES=("DepotKit")
MAIN_SCHEME_FOR_SITE="DepotKit"
HOSTING_BASE_PATH="/DepotKit"

DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro"
BUILD_DIR=".build"
SITE_DIR="docs/"
ARCHIVE_DIR="${SITE_DIR}archives/"
TMP_ARCHIVE_DIR="tmp/"
DOCCARCHIVE_DIR_FOR_SITE="${TMP_ARCHIVE_DIR}${MAIN_SCHEME_FOR_SITE}.doccarchive"

cd -P -- "$(dirname -- "$0")"
cd ..

if [ ! -d "$SITE_DIR" ]; then
    mkdir -p "$SITE_DIR"
fi

if [ ! -d "$TMP_ARCHIVE_DIR" ]; then
    mkdir -p "$TMP_ARCHIVE_DIR"
fi

for SCHEME in "${SCHEMES[@]}"; do
  echo "Building the documentation archive for $SCHEME"
  xcodebuild docbuild -workspace '.' -scheme $SCHEME -derivedDataPath $BUILD_DIR -destination "$DESTINATION" -skipPackagePluginValidation

  ARCHIVE=$(find $BUILD_DIR -type d -name "$SCHEME.doccarchive")
  echo "Processing archive in $ARCHIVE"

  cp -rf "$ARCHIVE" "${TMP_ARCHIVE_DIR}${SCHEME}.doccarchive"
done

echo "Building static documentation"
$(xcrun --find docc) process-archive transform-for-static-hosting "$DOCCARCHIVE_DIR_FOR_SITE" --hosting-base-path "$HOSTING_BASE_PATH" --output-path "$SITE_DIR"

if [ ! -d "$ARCHIVE_DIR" ]; then
    mkdir -p "$ARCHIVE_DIR"
fi
mv ${TMP_ARCHIVE_DIR}* ${ARCHIVE_DIR}

echo "Removing ${BUILD_DIR}"
rm -rf "$BUILD_DIR"
rm -rf "$TMP_ARCHIVE_DIR"
