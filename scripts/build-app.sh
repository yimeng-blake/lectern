#!/bin/bash
# Builds build/Lectern.app (release, ad-hoc signed).
#   scripts/build-app.sh                 build only
#   scripts/build-app.sh --open [x.pdf]  build, then open the app (optionally with a PDF)
#   scripts/build-app.sh --install       build, then copy to ~/Applications
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "VERSION must look like 1.2.3, got: '$VERSION'" >&2
    exit 1
fi
MIN_SWIFT_MAJOR=5
MIN_SWIFT_MINOR=10

OPEN=0
INSTALL=0
PDF=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --open)
            OPEN=1
            if [[ $# -gt 1 && "$2" != --* ]]; then PDF="$2"; shift; fi
            ;;
        --install) INSTALL=1 ;;
        -h|--help)
            sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done

if [[ -n "$PDF" ]]; then
    if [[ ! -f "$PDF" ]]; then
        echo "no such file: $PDF" >&2
        exit 2
    fi
    # Absolute, because the build runs from the repo root.
    PDF="$(cd "$(dirname "$PDF")" && pwd)/$(basename "$PDF")"
fi

# Prints "MAJOR MINOR" of the swift in developer directory $1; fails if there is none.
swift_version() {
    local out
    out="$(DEVELOPER_DIR="$1" swift --version 2>/dev/null </dev/null)" || return 1
    sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p' <<<"$out" | head -n 1
}

# Picks a toolchain with Swift >= 5.10: an explicit DEVELOPER_DIR first, then the Command Line Tools
# (if installed), then whatever `xcode-select` points at (often a full Xcode).
select_toolchain() {
    local candidates="" selected dir version major minor found="" tried=$'\n'
    [[ -n "${DEVELOPER_DIR:-}" ]] && candidates+="$DEVELOPER_DIR"$'\n'
    [[ -d /Library/Developer/CommandLineTools ]] && candidates+="/Library/Developer/CommandLineTools"$'\n'
    selected="$(env -u DEVELOPER_DIR xcode-select -p 2>/dev/null || true)"
    [[ -n "$selected" ]] && candidates+="$selected"$'\n'

    if [[ -z "$candidates" ]]; then
        echo "error: no Swift toolchain found." >&2
        echo "Install Apple's Command Line Tools with:  xcode-select --install" >&2
        exit 1
    fi

    while IFS= read -r dir; do
        [[ -n "$dir" && -d "$dir" ]] || continue
        [[ "$tried" == *$'\n'"$dir"$'\n'* ]] && continue
        tried+="$dir"$'\n'
        version="$(swift_version "$dir")" || continue
        [[ -n "$version" ]] || continue
        read -r major minor <<<"$version"
        if (( major > MIN_SWIFT_MAJOR || (major == MIN_SWIFT_MAJOR && minor >= MIN_SWIFT_MINOR) )); then
            export DEVELOPER_DIR="$dir"
            echo "Using Swift $major.$minor ($dir)"
            return 0
        fi
        found+="  Swift $major.$minor in $dir"$'\n'
    done <<<"$candidates"

    echo "error: Lectern needs Swift $MIN_SWIFT_MAJOR.$MIN_SWIFT_MINOR or later." >&2
    if [[ -n "$found" ]]; then
        printf 'Found:\n%s' "$found" >&2
        echo "Install or update the Command Line Tools (xcode-select --install, or System Settings >" >&2
        echo "General > Software Update), or install a newer Xcode and select it with:" >&2
        echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
    else
        echo "No working swift was found. Install the Command Line Tools with:  xcode-select --install" >&2
    fi
    exit 1
}

# Prints $1 with every extended-regex special character escaped (pgrep patterns are EREs).
regex_escape() {
    sed -E 's/[][\.*^$+?(){}|]/\\&/g' <<<"$1"
}

# Quits a Lectern running from bundle $1 (gracefully, so it stops its CLI children) before the bundle is
# replaced: `open` would otherwise just bring the old process, with the old code, to the front.
# Each matching process is asked to quit by pid, so a Lectern running from another bundle (for example
# build/ vs ~/Applications) is left alone; quitting by bundle id could pick that one instead.
quit_running_copy() {
    local pattern pid
    pattern="^$(regex_escape "$1/Contents/MacOS/Lectern")( |\$)"
    pgrep -qf -- "$pattern" || return 0
    echo "Quitting the Lectern running from $1"
    for pid in $(pgrep -f -- "$pattern"); do
        osascript -l JavaScript -e "ObjC.import('AppKit');
            var app = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid);
            if (app && !app.isNil()) { app.terminate; }" >/dev/null 2>&1 || true
    done
    for _ in $(seq 1 50); do
        pgrep -qf -- "$pattern" || return 0
        sleep 0.2
    done
    echo "Lectern is still running from $1; quit it and run this script again." >&2
    exit 1
}

select_toolchain

cd "$ROOT"
swift build -c release --product Lectern
BIN_DIR="$(swift build -c release --product Lectern --show-bin-path)"

APP="$ROOT/build/Lectern.app"
quit_running_copy "$APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Lectern" "$APP/Contents/MacOS/Lectern"
# Drop the debug map: it lists every object file and source folder by absolute path (the builder's
# home folder) in a binary that may be shared. Function names stay for crash reports. The linker's
# signature goes first so strip doesn't warn; the bundle is signed below.
codesign --remove-signature "$APP/Contents/MacOS/Lectern"
if ! strip -S "$APP/Contents/MacOS/Lectern"; then
    # Some strip versions (Command Line Tools 16) can't read every binary without its signature.
    echo "Stripping the signed binary instead"
    cp "$BIN_DIR/Lectern" "$APP/Contents/MacOS/Lectern"
    strip -S -no_code_signature_warning "$APP/Contents/MacOS/Lectern"
fi
# The chat page is not a SwiftPM resource (see Package.swift); the app loads it from Contents/Resources/web.
# -X: don't copy the sources' extended attributes (such as com.apple.provenance) into the bundle.
cp -RX "$ROOT/Sources/Lectern/Resources/web" "$APP/Contents/Resources/web"
cp -X "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"

# Optional app icon (CFBundleIconFile is only set when the file exists).
ICON_PLIST=""
ICON="$ROOT/Sources/Lectern/Resources/AppIcon.icns"
if [[ -f "$ICON" ]]; then
    cp -X "$ICON" "$APP/Contents/Resources/AppIcon.icns"
    ICON_PLIST=$'\n    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>'
fi

# PDFs are declared as a Viewer document type (Alternate rank) so Finder offers Open With → Lectern and
# sends open events to the app delegate. There is deliberately no NSDocumentClass: Lectern has no
# NSDocument and never writes to a PDF.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.lectern.app</string>
    <key>CFBundleName</key>
    <string>Lectern</string>
    <key>CFBundleDisplayName</key>
    <string>Lectern</string>
    <key>CFBundleExecutable</key>
    <string>Lectern</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>$ICON_PLIST
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

# cp -X still passes on com.apple.quarantine (sources from a downloaded ZIP carry it); clear every
# attribute so the bundle, and the release zip, carry none.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

if [[ $INSTALL -eq 1 ]]; then
    mkdir -p "$HOME/Applications"
    quit_running_copy "$HOME/Applications/Lectern.app"
    rm -rf "$HOME/Applications/Lectern.app"
    cp -R "$APP" "$HOME/Applications/Lectern.app"
    APP="$HOME/Applications/Lectern.app"
fi

echo "$APP"

if [[ $OPEN -eq 1 ]]; then
    if [[ -n "$PDF" ]]; then
        open -a "$APP" "$PDF"
    else
        open "$APP"
    fi
fi
