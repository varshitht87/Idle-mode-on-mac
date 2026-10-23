#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Idle Mode and packages it for sharing:
#   dist/IdleMode-<version>.dmg   drag-to-Applications disk image
#   dist/IdleMode-<version>.zip   the same app, zipped
# Double-click it in Finder, or run ./Scripts/package.command from the project folder.
set -uo pipefail
cd "$(dirname "$0")/.."

APP="Idle Mode"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
NAME="IdleMode-$VERSION"
STAGE="dist/$NAME"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p dist

{
    if ! xcrun swiftc --version >/dev/null 2>&1; then
        if [ -d /Library/Developer/CommandLineTools ]; then
            export DEVELOPER_DIR=/Library/Developer/CommandLineTools
        else
            echo "No Swift compiler found. Install one with: xcode-select --install"
            exit 1
        fi
    fi

    echo "› Packaging $APP $VERSION"
    rm -rf "$STAGE" "dist/$NAME.zip" "dist/$NAME.dmg"
    mkdir -p "$STAGE/$APP.app/Contents/MacOS" "$STAGE/$APP.app/Contents/Resources"

    for ARCH in arm64 x86_64; do
        echo "› Compiling ${ARCH}…"
        xcrun swiftc -O -swift-version 5 -parse-as-library \
            -target "$ARCH-apple-macos15.0" \
            -framework SwiftUI -framework AppKit -framework IOKit \
            Sources/*.swift -o "$TMP/$ARCH" || { echo "PACKAGE FAILED"; exit 1; }
    done
    xcrun lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$STAGE/$APP.app/Contents/MacOS/$APP"
    cp Resources/Info.plist "$STAGE/$APP.app/Contents/Info.plist"
    cp Resources/AppIcon.icns "$STAGE/$APP.app/Contents/Resources/AppIcon.icns"

    # Ad-hoc signature. With a Developer ID certificate, run with
    # SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" and notarise the result.
    if [ "${SIGN_IDENTITY:--}" = "-" ]; then
        codesign --force --sign - "$STAGE/$APP.app"
    else
        codesign --force --options runtime --timestamp --entitlements Resources/IdleMode.entitlements \
            --sign "$SIGN_IDENTITY" "$STAGE/$APP.app"
    fi
    xattr -cr "$STAGE/$APP.app"
    codesign --verify --strict "$STAGE/$APP.app"
    cp "Scripts/Install Idle Mode.txt" "$STAGE/"

    # ditto keeps the code signature intact (plain zip can break it).
    ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "dist/$NAME.zip"

    echo "› Making the disk image…"
    mkdir -p "$TMP/dmg"
    ditto --norsrc --noextattr "$STAGE/$APP.app" "$TMP/dmg/$APP.app"
    ln -s /Applications "$TMP/dmg/Applications"
    cp "Scripts/Install Idle Mode.txt" "$TMP/dmg/"
    hdiutil create -volname "$APP $VERSION" -srcfolder "$TMP/dmg" -ov -format UDZO "dist/$NAME.dmg" >/dev/null

    echo "✓ dist/$NAME.dmg  ($(du -h "dist/$NAME.dmg" | cut -f1))"
    echo "✓ dist/$NAME.zip  ($(du -h "dist/$NAME.zip" | cut -f1))"
    echo "  Architectures: $(lipo -archs "$STAGE/$APP.app/Contents/MacOS/$APP")"
} 2>&1 | tee dist/package.log
