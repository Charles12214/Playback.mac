#!/usr/bin/env zsh
set -e
killall Playback 2>/dev/null || true
export SDKROOT=$(xcrun --show-sdk-path)
if [[ "$SDKROOT" == *"/CommandLineTools/"* ]] && \
   [ ! -f "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] && \
   [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk" ]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
fi
BUILD_DIR="/tmp/playback-build"
echo "🔨 Building Playback..."
swift build -c release --build-path "$BUILD_DIR"

APP="Playback.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/release/Playback" "$APP/Contents/MacOS/Playback"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Playback</string>
  <key>CFBundleDisplayName</key><string>Playback</string>
  <key>CFBundleIdentifier</key><string>com.appsdotmac.playback</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleExecutable</key><string>Playback</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Playback reads the current playback position from Music to keep lyrics in sync.</string>
</dict></plist>
PL
echo -n "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "✨ Built $APP — run: open $APP"
