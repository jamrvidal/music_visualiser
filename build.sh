#!/bin/bash
# Builds JVisuals.app into ./build. Pass --run to launch it afterwards.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/JVisuals.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Plain swiftc rather than `swift build`, which needs a matching SwiftPM install.
# MacOSX.sdk is the SDK the installed compiler was built against; xcrun's default may be newer.
SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
swiftc -O -parse-as-library -sdk "$SDK" -target arm64-apple-macos14.2 \
    -o "$APP/Contents/MacOS/JVisuals" Sources/JVisuals/*.swift
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--run" ]]; then
    open "$APP"
fi
