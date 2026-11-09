#!/bin/bash
# Installs the package and tests the datasource against this system's own
# cloud-init, under coverage. Fails if the tests run less than MIN_COVERAGE
# percent of the installed code's statements and branches. Runs as root in a
# throwaway container of each supported system, after setup-cloud-init.sh.
# Usage: datasource.sh <path to .deb>
# With COVERAGE_REPORT set, also writes to that file, one per line: the system
# and its cloud-init version, MIN_COVERAGE, the total coverage, and the
# coverage check's exit status (0 when the total meets MIN_COVERAGE). The last
# two are missing if the tests fail before coverage is measured.
set -euo pipefail

DEB="$(realpath "${1:?usage: datasource.sh <deb>}")"
TEST="$(realpath "$(dirname "$0")/test_datasource.py")"
REPORT="$(realpath -m "${COVERAGE_REPORT:-/dev/null}")"
SITE=/usr/lib/python3/dist-packages
MIN_COVERAGE=98
export DEBIAN_FRONTEND=noninteractive
# The release tag the package was built from, which build-deb.sh puts in the
# file name. test_datasource.py checks the requests carry it.
SC_GUEST_VERSION="$(basename "$DEB" | sed -n 's/^sc-guest_\(.*\)_all\.deb$/\1/p')"
if [[ -z "$SC_GUEST_VERSION" ]]; then
  echo "no version in the file name $DEB, want sc-guest_<tag>_all.deb" >&2
  exit 1
fi
export SC_GUEST_VERSION

{
  echo "$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release)," \
    "cloud-init $(dpkg-query -W -f '${Version}' cloud-init)"
  echo "$MIN_COVERAGE"
} > "$REPORT"

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

status=0
python3 -I -m coverage report --show-missing --precision=1 \
  --fail-under="$MIN_COVERAGE" > report.txt || status=$?
cat report.txt
{
  # Prints an empty line if there's no total, so the file keeps its layout.
  awk '$1 == "TOTAL" { total = $NF } END { print total }' report.txt
  echo "$status"
} >> "$REPORT"
exit "$status"
