#!/bin/bash
# Builds a release Lectern.app and packages it for GitHub Releases:
#   dist/Lectern-<version>-arm64.zip  and  dist/Lectern-<version>-arm64.zip.sha256
# The app keeps build-app.sh's ad-hoc signature (it is not notarized).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

case "${1:-}" in
    "") ;;
    -h|--help)
        sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "unknown argument: $1" >&2
        exit 2
        ;;
esac

bash "$ROOT/scripts/build-app.sh"

APP="$ROOT/build/Lectern.app"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Lectern")"
if [[ "$ARCHS" != "arm64" ]]; then
    echo "error: expected an arm64-only binary, got: $ARCHS" >&2
    exit 1
fi
codesign --verify --deep --strict "$APP"
# The archive is published: refuse if any file in the app embeds a local path (e.g. your user name).
for path in "$ROOT" "$HOME"; do
    if LC_ALL=C grep -r -a -F -q -- "$path" "$APP"; then
        echo "error: Lectern.app contains the local path $path:" >&2
        LC_ALL=C grep -r -a -F -l -- "$path" "$APP" >&2
        exit 1
    fi
done

DIST="$ROOT/dist"
NAME="Lectern-$VERSION-arm64.zip"
ZIP="$DIST/$NAME"
mkdir -p "$DIST"
rm -f "$ZIP" "$ZIP.sha256"
# No resource forks or extended attributes (e.g. com.apple.provenance): with them ditto adds __MACOSX/._*
# entries, which unzip tools other than Archive Utility extract as a stray folder. The signature doesn't
# depend on them.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
ENTRIES="$(unzip -Z1 "$ZIP")"
if grep -q '^__MACOSX/' <<<"$ENTRIES"; then
    echo "error: $ZIP contains __MACOSX entries" >&2
    exit 1
fi
# The checksum file names the zip without a path, so `shasum -a 256 -c` works from the download folder.
(cd "$DIST" && shasum -a 256 "$NAME" > "$NAME.sha256")

echo
echo "Release archive: $ZIP"
echo "SHA-256:         $ZIP.sha256"
cat "$ZIP.sha256"
