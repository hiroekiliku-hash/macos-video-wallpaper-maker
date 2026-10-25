#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
BASE=/private/tmp/WallpaperMakerDistribution
PACKAGE="$BASE/壁纸制作器"
APP="${WALLPAPER_MAKER_APP:-/private/tmp/WallpaperMakerBuild/壁纸制作器.app}"
DIST="${WALLPAPER_MAKER_DIST:-$ROOT/dist}"
[[ ! -e "$PACKAGE" ]] || { print -u2 '已有打包目录，请保留或移走旧打包目录后重试。'; exit 1; }
/bin/mkdir -p "$PACKAGE/源码" "$DIST"
/usr/bin/ditto --noextattr --norsrc "$APP" "$PACKAGE/壁纸制作器.app"
for name in Engine Maker; do /usr/bin/ditto --noextattr "$ROOT/$name" "$PACKAGE/源码/$name"; done
for name in build.sh package.sh BuildIcon.swift 安装制作器.command 使用说明.txt README.md LICENSE THIRD_PARTY_NOTICES.md; do
  /bin/cp "$ROOT/$name" "$PACKAGE/源码/$name"
done
/bin/cp "$ROOT/使用说明.txt" "$PACKAGE/使用说明.txt"
/usr/bin/python3 - "$ROOT/安装制作器.command" "$PACKAGE" <<'PY'
from pathlib import Path
import subprocess, sys
package=Path(sys.argv[2])
data=subprocess.check_output(['/usr/bin/codesign','-d','--verbose=4',str(package/'壁纸制作器.app')],stderr=subprocess.STDOUT).decode()
digest=next(x.split('=',1)[1] for x in data.splitlines() if x.startswith('CDHash='))
script=package/'安装制作器.command'
script.write_text(Path(sys.argv[1]).read_text().replace('__CDHASH__',digest));script.chmod(0o755)
PY
/usr/bin/ditto -c -k --keepParent --noextattr --norsrc "$PACKAGE" "$DIST/壁纸制作器.zip.partial"
/bin/mv "$DIST/壁纸制作器.zip.partial" "$DIST/壁纸制作器.zip"
print -r -- "$PACKAGE"
