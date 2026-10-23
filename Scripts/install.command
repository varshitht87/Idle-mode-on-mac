#!/bin/bash
# Builds Idle Mode for this Mac and installs it in /Applications.
# Double-click it in Finder, or run ./Scripts/install.command from the project folder.
set -uo pipefail
cd "$(dirname "$0")/.."

APP="Idle Mode"
OUT="build/$APP.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p build

{
    # Use the Command Line Tools if Xcode is installed but its licence hasn't been accepted yet.
    if ! xcrun swiftc --version >/dev/null 2>&1; then
        if [ -d /Library/Developer/CommandLineTools ]; then
            export DEVELOPER_DIR=/Library/Developer/CommandLineTools
        else
            echo "No Swift compiler found. Install one with: xcode-select --install"
            exit 1
        fi
    fi

    echo "› Building $APP ($(uname -m))…"
    rm -rf "$OUT"
    mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
    xcrun swiftc -O -swift-version 5 -parse-as-library \
        -target "$(uname -m)-apple-macos15.0" \
        -framework SwiftUI -framework AppKit -framework IOKit \
        Sources/*.swift -o "$OUT/Contents/MacOS/$APP" || { echo "BUILD FAILED"; exit 1; }
    cp Resources/Info.plist "$OUT/Contents/Info.plist"
    cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
    codesign --force --sign - "$OUT" >/dev/null 2>&1

    echo "› Installing in /Applications…"
    pkill -x "$APP" && sleep 1
    rm -rf "/Applications/$APP.app"
    ditto "$OUT" "/Applications/$APP.app"
    "$LSREGISTER" -u "$PWD/$OUT" 2>/dev/null
    "$LSREGISTER" -f "/Applications/$APP.app"
    open "/Applications/$APP.app"
    echo "✓ Installed /Applications/$APP.app"
} 2>&1 | tee build/install.log
