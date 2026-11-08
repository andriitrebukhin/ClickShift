#!/bin/zsh
# Builds ClickShift.app (release) and ad-hoc signs it. Requires only Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClickShift"

APP="build/ClickShift.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/ClickShift"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature (local use only). Not sandboxed: posting key events needs Accessibility.
codesign --force --sign - --identifier io.github.andriitrebukhin.clickshift "$APP"

# Disk image for GitHub Releases: app + Applications shortcut over a background with an arrow.
DMG="build/ClickShift.dmg"
RW="build/ClickShift-rw.dmg"
STAGE="build/dmg"
VOL="ClickShift"
rm -rf "$STAGE" "$DMG" "$RW"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"

# Detach a leftover volume with the same name, then build a writable image to lay out.
[ -d "/Volumes/$VOL" ] && hdiutil detach "/Volumes/$VOL" -quiet || true
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
hdiutil attach "$RW" -readwrite -noverify -noautoopen -quiet

# Window 640×400 (+ title bar), 128 pt icons; positions match the arrow in the background.
osascript <<OSA || echo "warning: Finder layout failed (allow Terminal to control Finder); DMG will use the default layout"
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 840, 548}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "ClickShift.app" of container window to {160, 190}
        set position of item "Applications" of container window to {480, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA

rm -rf "/Volumes/$VOL/.fseventsd"
sync
hdiutil detach "/Volumes/$VOL" -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -rf "$STAGE" "$RW"

echo "Built $APP and $DMG"
echo "Run with: open $APP"
