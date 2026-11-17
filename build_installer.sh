#!/usr/bin/env zsh
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

echo "🚀 Starting Playback.mac Public Installer Build..."

# 1. Compile the latest release app
./build_app.sh

APP_BUNDLE="Playback.app"
if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ Error: $APP_BUNDLE was not found."
    exit 1
fi

VERSION="1.0.0"
DMG_NAME="Playback-${VERSION}.dmg"
PKG_NAME="Playback-${VERSION}.pkg"
VOL_NAME="Playback"

# 2. Create .pkg Installer
echo "📦 Generating macOS .pkg Installer Package (${PKG_NAME})..."
rm -f "${PKG_NAME}"
pkgbuild \
    --component "${APP_BUNDLE}" \
    --install-location "/Applications" \
    --identifier "com.appsdotmac.playback" \
    --version "${VERSION}" \
    "${PKG_NAME}"

echo "✅ Created ${PKG_NAME} successfully!"

# 3. Create .dmg Disk Image
echo "💿 Creating macOS Disk Image (${DMG_NAME})..."

STAGING_DIR="build_dmg_staging"
rm -rf "${STAGING_DIR}" "temp.dmg" "${DMG_NAME}"
mkdir -p "${STAGING_DIR}"

cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${STAGING_DIR}/.VolumeIcon.icns"
fi

APP_SIZE_MB=$(du -sm "${APP_BUNDLE}" | awk '{print $1}')
DMG_SIZE_MB=$((APP_SIZE_MB + 30))

hdiutil create \
    -srcfolder "${STAGING_DIR}" \
    -volname "${VOL_NAME}" \
    -fs HFS+ \
    -format UDRW \
    -size "${DMG_SIZE_MB}m" \
    temp.dmg

echo "   -> Finalizing DMG..."
hdiutil convert temp.dmg \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DMG_NAME}"

rm -rf "${STAGING_DIR}" temp.dmg

echo "🎉 Successfully built ${DMG_NAME} ($(du -sh "${DMG_NAME}" | awk '{print $1}')) and ${PKG_NAME} ($(du -sh "${PKG_NAME}" | awk '{print $1}'))!"
