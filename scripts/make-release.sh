#!/bin/zsh
# Builds RAMble.app and zips it for a GitHub release.
# Publish with:  gh release create v<version> build/RAMble.app.zip \
#                  --title "RAMble <version>" --notes "<what changed>"
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh
cd build
rm -f RAMble.app.zip
ditto -ck --keepParent RAMble.app RAMble.app.zip
echo "Release asset: build/RAMble.app.zip"
