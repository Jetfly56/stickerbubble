#!/bin/bash
set -e

REPO="Jetfly56/stickerbubble"
INSTALL_DIR="$HOME/Applications"
APP_NAME="StickerBubble.app"

echo "Fetching latest release..."
DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep '"browser_download_url"' \
  | grep '\.zip"' \
  | sed -E 's/.*"([^"]+)"/\1/')

if [ -z "$DOWNLOAD_URL" ]; then
  echo "Error: could not find a release to download."
  exit 1
fi

TMP_DIR=$(mktemp -d)
ZIP="$TMP_DIR/StickerBubble.zip"

echo "Downloading $DOWNLOAD_URL..."
curl -fsSL "$DOWNLOAD_URL" -o "$ZIP"

echo "Installing..."
xattr -cr "$ZIP"
unzip -q "$ZIP" -d "$TMP_DIR"

NEW_APP=$(find "$TMP_DIR" -name "*.app" -maxdepth 2 | head -1)
if [ -z "$NEW_APP" ]; then
  echo "Error: no .app found in archive."
  rm -rf "$TMP_DIR"
  exit 1
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME"
cp -R "$NEW_APP" "$INSTALL_DIR/$APP_NAME"
xattr -cr "$INSTALL_DIR/$APP_NAME"
rm -rf "$TMP_DIR"

echo "Installed to $INSTALL_DIR/$APP_NAME"
echo "Opening..."
open "$INSTALL_DIR/$APP_NAME"
