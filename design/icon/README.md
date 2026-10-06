# App icon

Sources for `Sources/Lectern/Resources/AppIcon.icns`. The design is a closing quote pair in cobalt
`#2F5BEA` over an open book in ink `#191919`, on a flat white tile.

| File | Used for | Notes |
| --- | --- | --- |
| `AppIcon.svg` | 128 px and up (128, 256, 512, 1024) | Master. 824 × 824 tile centered on 1024, radius 185, 2 px `#E6E4E0` hairline, soft shadow inside the margin. |
| `AppIcon-64.svg` | `icon_32x32@2x` | Same mark with a wider book and a pixel-aligned spine gap. |
| `AppIcon-32.svg` | `icon_16x16@2x` | Bolder quotes with a curled tail, book on the 32 px grid. |

The small SVGs are drawn on their own pixel grids. Render each one only at its native size.

There is deliberately no 1x 16 pt or 32 pt image (`icon_16x16.png`, `icon_32x32.png`). On macOS 26 those sizes
are drawn inside a gray plate on non-Retina screens; without them, macOS uses the @2x images instead.

## Regenerating the .icns

You need Google Chrome (used headless to rasterize the SVGs) and Xcode's command line tools (for `iconutil`).

```sh
design/icon/make-icns.sh          # writes Sources/Lectern/Resources/AppIcon.icns
design/icon/make-icns.sh out.icns /tmp/AppIcon.iconset   # other output; keeps the PNGs
```

`scripts/build-app.sh` copies the .icns into the bundle and sets `CFBundleIconFile`.

To do it by hand: render each SVG through an `<img>` wrapper page at the target size. Chrome renders a bare
SVG document only at its own width and height. Then run `iconutil`:

```sh
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# wrapper: <style>html,body{margin:0;background:transparent}img{display:block;width:N px;height:N px}</style><img src="file:///abs/AppIcon.svg">
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --default-background-color=00000000 --allow-file-access-from-files \
  --window-size=N,N --screenshot=/abs/out.png file:///abs/wrapper.html
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

The iconset needs these files:

- `icon_16x16@2x.png`: `AppIcon-32.svg` at 32
- `icon_32x32@2x.png`: `AppIcon-64.svg` at 64
- `icon_128x128.png`: `AppIcon.svg` at 128
- `icon_128x128@2x.png`, `icon_256x256.png`: `AppIcon.svg` at 256
- `icon_256x256@2x.png`, `icon_512x512.png`: `AppIcon.svg` at 512
- `icon_512x512@2x.png`: `AppIcon.svg` at 1024
