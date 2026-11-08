#!/bin/zsh
# Builds a release: build/release/ClickShift-<version>.dmg + .sha256 checksum.
#
#   ./release.sh 0.2.0             build artifacts only (sets the version in Info.plist)
#   ./release.sh 0.2.0 --publish   also commit the version bump, tag v0.2.0, push,
#                                  and create a GitHub Release with both files attached
#
# Publishing needs the GitHub CLI (`gh auth login`) with push access to the repo.
set -euo pipefail
cd "$(dirname "$0")"

REPO="andriitrebukhin/ClickShift"
PLIST="Resources/Info.plist"

VERSION="${1:-}"
PUBLISH="${2:-}"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || [[ -n "$PUBLISH" && "$PUBLISH" != "--publish" ]]; then
    echo "usage: ./release.sh X.Y.Z [--publish]" >&2
    exit 1
fi
TAG="v$VERSION"
NAME="ClickShift-$VERSION"
OUT="build/release"

# --- Pre-flight checks for publishing (before anything is modified) ---
if [[ "$PUBLISH" == "--publish" ]]; then
    command -v gh >/dev/null || { echo "error: GitHub CLI (gh) not found" >&2; exit 1; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not a git repository" >&2; exit 1; }
    [[ -z "$(git status --porcelain)" ]] || { echo "error: commit or stash your changes first" >&2; exit 1; }
    if git rev-parse "$TAG" >/dev/null 2>&1 || gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
        echo "error: $TAG already exists" >&2; exit 1
    fi
fi

# --- Tests must pass before anything is changed ---
echo "==> Running tests"
swift test

# --- Version: X.Y.Z for users, build number +1 for macOS ---
BUILD_NUMBER=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
echo "==> Version $VERSION (build $BUILD_NUMBER)"

# --- Build app + DMG ---
./build.sh

# --- Versioned artifacts + checksum ---
rm -rf "$OUT"
mkdir -p "$OUT"
cp build/ClickShift.dmg "$OUT/$NAME.dmg"
( cd "$OUT" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256" && shasum -a 256 -c "$NAME.dmg.sha256" >/dev/null )
echo "==> $OUT/$NAME.dmg"
echo "==> $OUT/$NAME.dmg.sha256: $(cut -d' ' -f1 "$OUT/$NAME.dmg.sha256")"

if [[ "$PUBLISH" != "--publish" ]]; then
    echo
    echo "Artifacts ready. To publish: commit $PLIST, then run ./release.sh $VERSION --publish"
    echo "(or create the release on GitHub and attach both files)."
    exit 0
fi

# --- Publish ---
git add "$PLIST"
git commit -m "Release $TAG"
git tag -a "$TAG" -m "ClickShift $VERSION"
# Push with the gh login, so it works even if git itself has no GitHub credentials.
git -c credential.helper= -c credential.helper='!gh auth git-credential' push origin HEAD "$TAG"

gh release create "$TAG" "$OUT/$NAME.dmg" "$OUT/$NAME.dmg.sha256" \
    --repo "$REPO" \
    --title "ClickShift $VERSION" \
    --generate-notes \
    --verify-tag

echo "==> Published https://github.com/$REPO/releases/tag/$TAG"
