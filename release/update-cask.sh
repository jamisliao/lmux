#!/bin/bash
# release/update-cask.sh X.Y.Z
#
# Fills release/lmux.rb's `version` and `sha256` from the sha256 file that
# release/package.sh wrote (release/out/lmux-X.Y.Z-arm64.sha256.txt).
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: release/update-cask.sh X.Y.Z" >&2
  exit 1
fi
VERSION="$1"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like X.Y.Z (got: $VERSION)" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHA_FILE="$REPO_ROOT/release/out/lmux-$VERSION-arm64.sha256.txt"
CASK_FILE="$REPO_ROOT/release/lmux.rb"
ZIP_NAME="lmux-$VERSION-arm64.zip"

if [[ ! -f "$SHA_FILE" ]]; then
  echo "error: $SHA_FILE not found. Run release/package.sh --version $VERSION first." >&2
  exit 1
fi

SHA256="$(awk -v f="$ZIP_NAME" '$2==f || $2=="*"f {print $1; exit}' "$SHA_FILE")"
if [[ -z "$SHA256" ]]; then
  echo "error: could not find the sha256 for $ZIP_NAME in $SHA_FILE" >&2
  exit 1
fi

sed -i '' -E "s/^  version \"[^\"]*\"/  version \"$VERSION\"/" "$CASK_FILE"
sed -i '' -E "s/^  sha256 \"[^\"]*\"/  sha256 \"$SHA256\"/" "$CASK_FILE"

echo "Updated $CASK_FILE:"
echo "  version = $VERSION"
echo "  sha256  = $SHA256"
