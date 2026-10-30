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

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$tmp/arm64" "$here/iHypnusCare.swift" -framework Cocoa -framework WebKit

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/tools/assets"
cp "$tmp/arm64" "$app/Contents/MacOS/iHypnusCare"

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

cat > "$app/Contents/Info.plist" <<'PLIST'
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
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
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
