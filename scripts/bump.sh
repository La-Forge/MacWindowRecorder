#!/usr/bin/env bash
# Usage: ./scripts/bump.sh [major|minor|patch]
# Bumps CFBundleShortVersionString in Info.plist, commits, tags, and pushes.

set -euo pipefail

PART=${1:-patch}
PLIST="TabRecordApp/Info.plist"

current=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
IFS='.' read -r major minor patch <<< "$current"

case "$PART" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "Usage: $0 [major|minor|patch]" >&2; exit 1 ;;
esac

next="$major.$minor.$patch"

# Update Info.plist
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $next" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $next" "$PLIST"

echo "Bumped $current → $next"

git add "$PLIST"
git commit -m "chore: bump version to $next"
git tag -a "v$next" -m "Release v$next"
git push origin HEAD
git push origin "v$next"

echo "Tagged and pushed v$next"
