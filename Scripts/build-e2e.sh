#!/bin/sh
# Builds the end-to-end test runner and the WindowFactory test app into ./build/e2e.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c release --product moss-e2e
swift build -c release --product WindowFactory
binaries="$(swift build -c release --show-bin-path)"

out="build/e2e"
app="$out/WindowFactory.app"
rm -rf "$out"
mkdir -p "$app/Contents/MacOS"
cp "$binaries/moss-e2e" "$out/moss-e2e"
cp "$binaries/WindowFactory" "$app/Contents/MacOS/WindowFactory"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>WindowFactory</string>
    <key>CFBundleIdentifier</key><string>app.moss.WindowFactory</string>
    <key>CFBundleName</key><string>WindowFactory</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $out"
