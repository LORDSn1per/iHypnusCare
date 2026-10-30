#!/bin/bash
# Builds "iHypnusCare.app" next to the tools folder. Re-run after changing the reader, template or Swift app.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tools="$(dirname "$here")"
dest="$(dirname "$tools")/iHypnusCare.app"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# assemble and sign on local disk: codesign rejects bundles on SMB shares (AppleDouble/xattr detritus)
app="$tmp/iHypnusCare.app"

version="1.10"
build="3"

# Universal binary: Apple Silicon (macOS 11+) and Intel (macOS 10.14.4+, the first release with Swift built in).
# Current Command Line Tools ship the Swift back-deployment shims for arm64 only, so they're switched off
# (-runtime-compatibility-version none). The app uses no Swift features that need them.
for target in arm64-apple-macos11.0 x86_64-apple-macos10.14.4; do
  swiftc -O -swift-version 5 -runtime-compatibility-version none -target "$target" \
    -o "$tmp/${target%%-*}" "$here/iHypnusCare.swift" -framework Cocoa -framework WebKit
done

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/tools/assets"
lipo -create "$tmp/arm64" "$tmp/x86_64" -output "$app/Contents/MacOS/iHypnusCare"

# bundle the reader, template and images
cp "$tools/hypnus_report.py" "$tools/report_template.html" "$app/Contents/Resources/tools/"
cp "$tools/assets/hypnus-logo.png" "$tools/assets/device.jpg" "$app/Contents/Resources/tools/assets/"

# app icon
set=$tmp/icon.iconset
mkdir "$set"
for s in 16 32 128 256 512; do
  sips -z $s $s "$tools/assets/app-icon.png" --out "$set/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); [ $d -le 512 ] || d=512
  sips -z $d $d "$tools/assets/app-icon.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>iHypnusCare</string>
  <key>CFBundleDisplayName</key><string>iHypnusCare</string>
  <key>CFBundleExecutable</key><string>iHypnusCare</string>
  <key>CFBundleIdentifier</key><string>local.ihypnuscare</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${build}</string>
  <key>LSMinimumSystemVersion</key><string>10.14.4</string>
  <key>LSMinimumSystemVersionByArchitecture</key>
  <dict>
    <key>arm64</key><string>11.0</string>
    <key>x86_64</key><string>10.14.4</string>
  </dict>
  <key>LSArchitecturePriority</key><array><string>arm64</string><string>x86_64</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Unofficial tool. Not made or endorsed by Hypnus.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

xattr -cr "$app"
codesign --force --deep -s - "$app"
rm -rf "$dest"
ditto "$app" "$dest"
touch "$dest"
echo "Built: $dest"
