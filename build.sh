#!/bin/sh
# Builds mc (CLI) and mc.app, installs the app to /Applications.
set -e
cd "$(dirname "$0")"
swiftc -O mc.swift -o mc
mkdir -p mc.app/Contents/MacOS
cp mc mc.app/Contents/MacOS/mc
cat > mc.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>mc</string>
  <key>CFBundleIdentifier</key><string>com.dliver.mc</string>
  <key>CFBundleName</key><string>mc</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Disco mode pulses the screen with the music.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Turns the monitor off when your phone or watch walks away.</string>
</dict></plist>
PLIST
codesign --force -s - mc.app
pkill -x mc || true
rm -rf /Applications/mc.app
cp -R mc.app /Applications/
open /Applications/mc.app
