#!/bin/sh
# Publishes the pushed HEAD as a GitHub release with Moss.app attached as a zip.
#
#   Scripts/release.sh [NOTES.md]
#
# The release is named after the app's version, so raise `current` in
# Sources/MossRuntime/Engine/CommandRunner.swift first. NOTES.md, if given, opens the release
# notes. The app is signed ad hoc and not notarized; the README explains how to open it.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fail() {
    echo "release: $1" >&2
    exit 1
}

[ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first"
git fetch --quiet origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse '@{upstream}')" ] || fail "push this commit first"

version="$(sed -n 's/.*static let current = "\(.*\)"/\1/p' Sources/MossRuntime/Engine/CommandRunner.swift)"
tag="v$version"
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
    fail "$tag is already released; raise the version first"
fi

MOSS_SIGNING_IDENTITY=- Scripts/build-app.sh release --universal
codesign --verify --strict build/Moss.app

archive="build/Moss-$version.zip"
rm -f "$archive"
ditto -c -k --keepParent build/Moss.app "$archive"

repository="$(gh repo view --json url --jq .url)"
notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
if [ -n "${1:-}" ]; then
    cat "$1" >"$notes"
    printf '\n' >>"$notes"
fi
cat >>"$notes" <<NOTES
## Installing

Unzip Moss-$version.zip and move Moss.app to Applications. Moss is not notarized, so the
first time you open it macOS refuses: click Done, then Open Anyway in System Settings ›
Privacy & Security. More in the [README]($repository#installing).
NOTES

gh release create "$tag" "$archive" --target "$(git rev-parse HEAD)" --title "Moss $version" --notes-file "$notes"
