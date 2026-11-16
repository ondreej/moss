#!/bin/sh
# Builds Moss.app into ./build.
#
#   Scripts/build-app.sh [debug|release] [--universal]
#
# --universal builds for both Apple silicon and Intel Macs.
#
# Set MOSS_SIGNING_IDENTITY to sign with a certificate; otherwise the bundle is
# signed ad hoc. A stable identity keeps the Accessibility permission across rebuilds.
set -eu

configuration="${1:-release}"
architectures=""
if [ "${2:-}" = "--universal" ]; then
    architectures="--arch arm64 --arch x86_64"
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# $architectures is left unquoted so that it splits into separate arguments.
swift build -c "$configuration" $architectures --product Moss
swift build -c "$configuration" $architectures --product MossCLI
binaries="$(swift build -c "$configuration" $architectures --show-bin-path)"

app="build/Moss.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$binaries/Moss" "$app/Contents/MacOS/Moss"
# The command-line tool lives apart from the app: file names ignore case, so `moss` and
# `Moss` cannot share a directory.
cp "$binaries/MossCLI" "$app/Contents/Helpers/moss"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi

version="$(sed -n 's/.*static let current = "\(.*\)"/\1/p' Sources/MossRuntime/Engine/CommandRunner.swift)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"

identity="${MOSS_SIGNING_IDENTITY:--}"
codesign --force --options runtime --sign "$identity" "$app/Contents/Helpers/moss"
codesign --force --options runtime --sign "$identity" "$app"

echo "Built $app ($version, $configuration)"
