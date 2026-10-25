#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
BUILD=/private/tmp/WallpaperMakerBuild
OUT="$BUILD/壁纸制作器.app"
TEMPLATE="$BUILD/VideoWallpaper.app"
EXT="$TEMPLATE/Contents/Extensions/VideoWallpaperExtension.appex"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
MODULE_CACHE="${TMPDIR:-/private/tmp}/WallpaperMakerModuleCache"
/bin/mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$EXT/Contents/MacOS" "$EXT/Contents/Resources" "$TEMPLATE/Contents/MacOS"
/usr/bin/python3 - "$OUT" "$TEMPLATE" "$EXT" <<'PY'
import plistlib, sys
from pathlib import Path
for folder, ident, exe, display, kind in [
    (sys.argv[1], 'local.videowallpaper.maker', 'WallpaperMaker', '壁纸制作器', 'APPL'),
    (sys.argv[2], 'local.videowallpaper.template', 'VideoWallpaperHost', '壁纸', 'APPL'),
    (sys.argv[3], 'local.videowallpaper.template.extension', 'VideoWallpaperExtension', '壁纸', 'XPC!')]:
    info = dict(CFBundleIdentifier=ident, CFBundleExecutable=exe, CFBundleDisplayName=display,
                CFBundleName=display, CFBundlePackageType=kind, CFBundleShortVersionString='1.0.0',
                CFBundleVersion='1', LSMinimumSystemVersion='26.0', CFBundleSupportedPlatforms=['MacOSX'],
                CFBundleDevelopmentRegion='zh-Hans', CFBundleLocalizations=['zh-Hans'], CFBundleIconFile='AppIcon')
    if kind == 'XPC!': info['EXAppExtensionAttributes'] = dict(EXExtensionPointIdentifier='com.apple.wallpaper')
    else: info['NSPrincipalClass']='NSApplication'
    (Path(folder)/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun swift -module-cache-path "$MODULE_CACHE" "$ROOT/BuildIcon.swift" "$BUILD/AppIcon.iconset"
/usr/bin/iconutil -c icns "$BUILD/AppIcon.iconset" -o "$OUT/Contents/Resources/AppIcon.icns"
/bin/cp "$OUT/Contents/Resources/AppIcon.icns" "$TEMPLATE/Contents/Resources/AppIcon.icns" 2>/dev/null || {
  /bin/mkdir -p "$TEMPLATE/Contents/Resources"
  /bin/cp "$OUT/Contents/Resources/AppIcon.icns" "$TEMPLATE/Contents/Resources/AppIcon.icns"
}
xcrun swiftc -swift-version 5 -application-extension -O -whole-module-optimization \
  -target arm64-apple-macos26.0 -module-cache-path "$MODULE_CACHE" \
  -framework Cocoa -framework AVFoundation -framework IOSurface -framework ExtensionFoundation \
  -Xlinker -e -Xlinker _NSExtensionMain -import-objc-header "$ROOT/Engine/WallpaperBridge.h" \
  "$ROOT/Engine/NativeEntry.swift" "$ROOT/Engine/ContinuousRenderer.swift" \
  "$ROOT/Engine/WallpaperConfiguration.swift" "$ROOT"/Engine/Vendor/*.swift \
  -o "$EXT/Contents/MacOS/VideoWallpaperExtension"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
  -module-cache-path "$MODULE_CACHE" -framework Cocoa "$ROOT/Engine/Host.swift" \
  -o "$TEMPLATE/Contents/MacOS/VideoWallpaperHost"
/bin/cp "$ROOT/Engine/Vendor/PHOSPHENE-LICENSE" "$EXT/Contents/Resources/"
codesign --force --sign - --entitlements "$ROOT/Engine/Sandbox.entitlements" "$EXT"
codesign --force --sign - "$TEMPLATE"
if [[ "${1:-}" == --engine-only ]]; then exit 0; fi
/usr/bin/ditto -c -k --keepParent --noextattr --norsrc "$TEMPLATE" "$OUT/Contents/Resources/Template.zip"
/usr/bin/ditto --noextattr "$ROOT/Engine" "$OUT/Contents/Resources/EngineSources"
/usr/bin/ditto --noextattr "$ROOT/Maker" "$OUT/Contents/Resources/MakerSources"
/bin/cp "$ROOT/使用说明.txt" "$OUT/Contents/Resources/使用说明.txt"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
  -module-cache-path "$MODULE_CACHE" -framework Cocoa -framework AVFoundation -framework AVKit -framework CoreImage \
  "$ROOT"/Maker/*.swift "$ROOT/Engine/WallpaperConfiguration.swift" \
  -o "$OUT/Contents/MacOS/WallpaperMaker"
codesign --force --sign - "$OUT"
print -r -- "$OUT"
