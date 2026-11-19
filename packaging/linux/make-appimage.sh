#!/bin/sh
# make-appimage.sh <bin dir> <version> <x86_64|aarch64> <out dir>
#
# An AppImage of pstview and pstx from the release binaries. Like the release archive it uses
# the system's GTK 4 and WebKitGTK 6.0 (pstview loads them at run time); it bundles neither.
#
#   ./pstview-<version>-x86_64.AppImage [file ...]         the viewer
#   ./pstview-<version>-x86_64.AppImage pstx tree a.pst    the command-line tool
#
# Needs appimagetool on PATH (APPIMAGETOOL=<path> to use another one).
set -eu
bin=$1 version=$2 arch=$3 out=$4
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
app=$(mktemp -d)/pstview.AppDir
trap 'rm -rf "$(dirname "$app")"' EXIT

mkdir -p "$app/usr/bin" "$app/usr/share/applications" "$app/usr/share/icons/hicolor/256x256/apps" "$out"
install -m755 "$bin/pstview" "$bin/pstx" "$app/usr/bin/"
install -m644 "$here/pstview.desktop" "$app/usr/share/applications/pstview.desktop"
install -m644 "$root/design/icon-256.png" "$app/usr/share/icons/hicolor/256x256/apps/pstview.png"
# what appimagetool and desktop integration (AppImageLauncher, appimaged) read at the top
ln -s usr/share/applications/pstview.desktop "$app/pstview.desktop"
ln -s usr/share/icons/hicolor/256x256/apps/pstview.png "$app/pstview.png"
ln -s pstview.png "$app/.DirIcon"
cat > "$app/AppRun" <<'EOF'
#!/bin/sh
# pstview, or pstx when the first argument is "pstx"
here=$(dirname "$(readlink -f "$0")")
if [ "${1:-}" = pstx ]; then shift; exec "$here/usr/bin/pstx" "$@"; fi
exec "$here/usr/bin/pstview" "$@"
EOF
chmod 755 "$app/AppRun"

ARCH=$arch VERSION=$version "${APPIMAGETOOL:-appimagetool}" --no-appstream "$app" "$out/pstview-$version-$arch.AppImage"
