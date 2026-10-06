#!/bin/bash
# Regenerates the app icon from the SVG sources in this folder.
#   design/icon/make-icns.sh [out.icns] [iconset-dir]
# out.icns defaults to Sources/Lectern/Resources/AppIcon.icns; pass iconset-dir to keep the PNGs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$ROOT/Sources/Lectern/Resources/AppIcon.icns}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SET="${2:-$TMP/AppIcon.iconset}"
# iconutil needs a .iconset folder; refusing anything else keeps a mistyped path from being wiped.
[[ "$SET" == *.iconset ]] || { echo "iconset dir must end in .iconset" >&2; exit 1; }
rm -rf "$SET"
mkdir -p "$SET"

# render <svg> <px> <png>: draws the SVG at px x px on a transparent background. The SVG goes through
# an <img> so it scales to any size (a bare SVG document renders only at its own width/height).
render() {
    local src="$HERE/$1" html="$TMP/render.html"
    printf '<!doctype html><style>html,body{margin:0;background:transparent;overflow:hidden}img{display:block;width:%dpx;height:%dpx}</style><img src="file://%s">' \
        "$2" "$2" "${src// /%20}" > "$html"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
        --default-background-color=00000000 --allow-file-access-from-files \
        --window-size="$2,$2" --screenshot="$3" "file://$html" >/dev/null 2>&1
    if [[ "$(sips -g pixelWidth "$3" 2>/dev/null | awk '/pixelWidth/ {print $2}')" != "$2" ]]; then
        echo "render failed: $1 at $2 px" >&2
        exit 1
    fi
}

# 32 and 64 px use hand-tuned art; 128 px and up render the master. There is deliberately no 1x
# 16/32 pt art: macOS 26 draws it inside a gray plate, and without it uses the @2x art instead.
render AppIcon-32.svg 32 "$SET/icon_16x16@2x.png"
render AppIcon-64.svg 64 "$SET/icon_32x32@2x.png"
render AppIcon.svg 128 "$SET/icon_128x128.png"
render AppIcon.svg 256 "$SET/icon_128x128@2x.png"
cp "$SET/icon_128x128@2x.png" "$SET/icon_256x256.png"
render AppIcon.svg 512 "$SET/icon_256x256@2x.png"
cp "$SET/icon_256x256@2x.png" "$SET/icon_512x512.png"
render AppIcon.svg 1024 "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o "$OUT"
echo "$OUT"
