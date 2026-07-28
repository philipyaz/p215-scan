#!/bin/bash
# Build P215 Scan.app -- a plain swiftc build, no Xcode project needed.
set -euo pipefail

cd "$(dirname "$0")"

SDK="${SDK:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
TARGET="${TARGET:-arm64-apple-macos14.0}"
VERSION="${VERSION:-1.1.0}"
APP="build/P215 Scan.app"
NAME="P215 Scan"

if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
    echo "error: macOS SDK not found (is Xcode or the Command Line Tools installed?)" >&2
    echo "       set SDK=/path/to/MacOSX.sdk to override" >&2
    exit 1
fi

echo "==> compiling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc \
    -sdk "$SDK" \
    -target "$TARGET" \
    -O -whole-module-optimization \
    -framework SwiftUI -framework AppKit -framework Vision \
    -framework CoreImage -framework CoreGraphics -framework ImageIO \
    -framework UniformTypeIdentifiers -framework CoreText \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/$NAME"

echo "==> assembling bundle"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi
# Self-contained SANE (see bundle-sane.sh) so users need no Homebrew. Optional:
# without it the app falls back to a system scanimage.
if [ -x build/sane-bundle/bin/scanimage ]; then
    echo "==> bundling SANE"
    mkdir -p "$APP/Contents/Frameworks"
    cp -R build/sane-bundle "$APP/Contents/Frameworks/sane"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$NAME</string>
    <key>CFBundleDisplayName</key>       <string>$NAME</string>
    <key>CFBundleExecutable</key>        <string>$NAME</string>
    <key>CFBundleIdentifier</key>        <string>io.github.philipyaz.p215scan</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>The Canon P-215II is controlled through a small volume it presents over USB. Access is needed to send scan commands to it.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>So scans can be saved to your Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>So scans can be saved to your Documents folder.</string>
</dict>
</plist>
PLIST

echo "==> signing"
codesign -s - --force --timestamp=none "$APP" >/dev/null 2>&1 || \
    echo "   (ad-hoc signing failed; the app will still run locally)"

echo
echo "Built: $APP"
echo "Run:   open '$APP'"
