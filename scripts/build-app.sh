#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 1
fi

swift build -c "$configuration"
swift scripts/generate-icon.swift
bin_path="$(swift build -c "$configuration" --show-bin-path)"
app_path="$PWD/build/Skriv.app"
mkdir -p "$app_path/Contents/MacOS"
mkdir -p "$app_path/Contents/Resources"
mkdir -p "$app_path/Contents/Resources/bin"
cp "$bin_path/Skriv" "$app_path/Contents/MacOS/Skriv"
if [[ "$configuration" == "release" ]]; then
    # Keep the symbol-rich SwiftPM output for diagnostics; ship only the stripped copy.
    strip -S -x "$app_path/Contents/MacOS/Skriv"
fi
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp build/Skriv.icns "$app_path/Contents/Resources/Skriv.icns"
cp Resources/ThirdPartyNotices.txt "$app_path/Contents/Resources/ThirdPartyNotices.txt"
install -m 755 scripts/skriv "$app_path/Contents/Resources/bin/skriv"
codesign --force --sign - "$app_path"
echo "$app_path"
