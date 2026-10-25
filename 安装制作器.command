#!/bin/zsh
set -euo pipefail
PACKAGE="${0:A:h}"
SOURCE="$PACKAGE/壁纸制作器.app"
EXPECTED_HASH='__CDHASH__'
[[ "$(/usr/bin/uname -m)" == arm64 ]] || { print -u2 '需要 Apple Silicon Mac。'; exit 1; }
/usr/bin/codesign --verify --deep --strict "$SOURCE"
ACTUAL_HASH="$(/usr/bin/codesign -d --verbose=4 "$SOURCE" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2}')"
[[ "$ACTUAL_HASH" == "$EXPECTED_HASH" ]] || { print -u2 '程序校验不符，请重新获取完整安装包。'; exit 1; }
APPS="$HOME/Applications"
DEST="$APPS/壁纸制作器.app"
if [[ -e "$DEST" ]]; then
  IDENTIFIER="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$IDENTIFIER" == local.videowallpaper.maker ]] || { print -u2 '已有其他同名应用，请先在访达中处理名称冲突。'; exit 1; }
fi
/bin/mkdir -p "$APPS"
STAGE="$(/usr/bin/mktemp -d "$APPS/.WallpaperMaker.XXXXXX")"
BACKUP="$HOME/Library/Application Support/WallpaperMakerInstaller/Backups/$(/bin/date +%Y%m%d-%H%M%S)-$$"
OLD=0; NEW=0; COMMITTED=0
cleanup() {
  local exit_status=$?
  if (( ! COMMITTED )); then
    if (( NEW )); then /bin/mv "$DEST" "$STAGE/failed.app"; fi
    if (( OLD )); then /bin/mv "$BACKUP/壁纸制作器.app" "$DEST"; fi
  fi
  [[ "$STAGE" == "$APPS"/.WallpaperMaker.* ]] && /bin/rm -rf "$STAGE"
  return $exit_status
}
trap cleanup EXIT
/usr/bin/ditto --noextattr --norsrc --noqtn "$SOURCE" "$STAGE/壁纸制作器.app"
if [[ -e "$DEST" ]]; then /bin/mkdir -p "$BACKUP"; /bin/mv "$DEST" "$BACKUP/壁纸制作器.app"; OLD=1; fi
/bin/mv "$STAGE/壁纸制作器.app" "$DEST"; NEW=1
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
COMMITTED=1
if [[ "${WALLPAPER_MAKER_NO_OPEN:-0}" != 1 ]]; then /usr/bin/open "$DEST"; fi
print '壁纸制作器已安装。以后在应用程序或聚焦搜索里打开即可。'
