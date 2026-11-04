#!/bin/bash
# Builds the package into dist/ with a packages.sha256 next to it.
# Usage: build-deb.sh <tag>   (1.2.0, 1.2.0-beta.3, or 0.0.0-ci.42 for CI)
#
# Run it on Ubuntu 22.04, the oldest supported system. debhelper writes the
# package's install and remove scripts, and scripts written by a newer
# debhelper are not guaranteed to run on older systems.
set -euo pipefail

TAG="${1:?usage: build-deb.sh <tag>}"
cd "$(dirname "$0")/../.."

DEB_VERSION="$(.github/scripts/deb-version.sh "$TAG")"

# Generated rather than committed, so the version lives only in the tag.
cat > debian/changelog <<EOF
sc-guest (${DEB_VERSION}) unstable; urgency=medium

  * Release ${TAG}.

 -- Strettch Cloud <engineering@strettch.com>  $(date -u -R)
EOF

dpkg-buildpackage --build=all --no-sign

# The file is named after the tag, not the Debian version: GitHub renames
# release assets with characters such as "~". apt reads the version from the
# package itself, not from the file name.
mkdir -p dist
mv "../sc-guest_${DEB_VERSION}_all.deb" "dist/sc-guest_${TAG}_all.deb"
rm -f "../sc-guest_${DEB_VERSION}_all.buildinfo" "../sc-guest_${DEB_VERSION}_all.changes"
(cd dist && sha256sum -- *.deb > packages.sha256)

echo "Built dist/sc-guest_${TAG}_all.deb (version ${DEB_VERSION})"
