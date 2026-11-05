#!/bin/bash
# Installs the package and tests the datasource against this system's own
# cloud-init, under coverage. Fails if the tests run less than MIN_COVERAGE
# percent of the installed code's statements and branches. Runs as root in a
# throwaway container of each supported system, after setup-cloud-init.sh.
# Usage: datasource.sh <path to .deb>
# With COVERAGE_REPORT set, also writes the system's name and the coverage
# report to that file.
set -euo pipefail

DEB="$(realpath "${1:?usage: datasource.sh <deb>}")"
TEST="$(realpath "$(dirname "$0")/test_datasource.py")"
REPORT="$(realpath -m "${COVERAGE_REPORT:-/dev/null}")"
SITE=/usr/lib/python3/dist-packages
MIN_COVERAGE=98
export DEBIAN_FRONTEND=noninteractive

apt-get install --yes --quiet --quiet "$DEB" python3-coverage

# coverage puts the test's directory first on sys.path, even with -I, so the
# test runs from an empty directory and can only import the installed code.
# coverage's data goes there too, because the source may be mounted read-only.
WORK="$(mktemp -d)"
cp "$TEST" "$WORK/"
cd "$WORK"
export COVERAGE_FILE="$WORK/.coverage"
python3 -I -m coverage run --branch \
  --include="$SITE/DataSourceStrettchCloud.py,$SITE/sc_guest/*" \
  test_datasource.py -v
{
  echo "$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release)," \
    "cloud-init $(dpkg-query -W -f '${Version}' cloud-init)"
  python3 -I -m coverage report --show-missing --precision=1 \
    --fail-under="$MIN_COVERAGE"
} | tee "$REPORT"
