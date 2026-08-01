#!/bin/bash
# Build Caffeinate.app and package it as Caffeinate.app.zip — the same asset
# name the upstream repo attaches to its GitHub releases.
#
# After running this, publish with (pick your own tag/title/notes):
#   gh release create vX.Y.Z Caffeinate.app.zip --title "Version X.Y.Z" --notes "..."
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh

rm -f Caffeinate.app.zip
# ditto preserves the bundle structure and resource forks correctly (better
# than `zip` for .app bundles).
ditto -c -k --keepParent Caffeinate.app Caffeinate.app.zip
echo "Created Caffeinate.app.zip ($(du -h Caffeinate.app.zip | cut -f1))"
