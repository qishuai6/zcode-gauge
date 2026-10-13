#!/bin/bash
# ZCode 油表 · 编译打包脚本
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ZCodeGauge"
DISPLAY_NAME="ZCode 油表"
BUNDLE_ID="vip.qishuai.zcode-gauge"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "==> swiftc 编译"
swiftc -O \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  Sources/*.swift \
  -framework AppKit -framework ServiceManagement

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP"

echo "==> 完成: $APP"
du -sh "$APP"
