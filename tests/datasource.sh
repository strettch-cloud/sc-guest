#!/bin/bash
# Installs the package and tests the datasource against this system's own
# cloud-init. Runs as root in a throwaway container of each supported system,
# after setup-cloud-init.sh.
# Usage: datasource.sh <path to .deb>
set -euo pipefail

DEB="$(realpath "${1:?usage: datasource.sh <deb>}")"
export DEBIAN_FRONTEND=noninteractive

apt-get install --yes --quiet --quiet "$DEB"

# -I: import the installed modules, never copies next to the test.
python3 -I "$(dirname "$0")/test_datasource.py" -v
