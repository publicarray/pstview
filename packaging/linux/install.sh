#!/bin/sh
# Install pstview for the current user (no root): programs to ~/.local/bin, a menu entry and icon
# to ~/.local/share. Remove with: install.sh --uninstall
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin="$HOME/.local/bin"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
if [ "${1:-}" = "--uninstall" ]; then
	rm -f "$bin/pstview" "$bin/pstx" "$apps/pstview.desktop" "$icons/pstview.png"
	echo "pstview removed."
	exit 0
fi
mkdir -p "$bin" "$apps" "$icons"
install -m 755 "$here/pstview" "$here/pstx" "$bin/"
install -m 644 "$here/pstview.png" "$icons/pstview.png"
sed "s|^Exec=pstview|Exec=$bin/pstview|" "$here/pstview.desktop" > "$apps/pstview.desktop"
echo "pstview installed to $bin (menu entry added). It needs GTK 3 and WebKitGTK:"
echo "  Debian / Ubuntu:  sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0"
echo "  Fedora:           sudo dnf install gtk3 webkit2gtk4.1"
echo "  Arch:             sudo pacman -S gtk3 webkit2gtk-4.1"
