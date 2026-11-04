#!/bin/bash
# Installs, removes and purges the package, and checks that a purge leaves
# none of its files behind. Runs as root in a throwaway container of each
# supported system, after setup-cloud-init.sh.
# Usage: lifecycle.sh <path to .deb>
set -euo pipefail

DEB="$(realpath "${1:?usage: lifecycle.sh <deb>}")"
export DEBIAN_FRONTEND=noninteractive

apt-get install --yes --quiet --quiet "$DEB"
echo "installed: $(dpkg-query -W -f='${Package} ${Version}' sc-guest)"

files="$(mktemp)"
dpkg -L sc-guest | while read -r path; do
    if [[ -f "$path" || -L "$path" ]]; then echo "$path"; fi
done > "$files"
echo "files: $(wc -l < "$files")"

apt-get remove --yes --quiet --quiet sc-guest
echo "after remove: $(dpkg-query -W -f='${Status}' sc-guest 2>/dev/null || echo not-installed)"

# dpkg, not apt: a package installed from a file isn't in apt's lists, and
# one with no settings files is already gone after the remove.
dpkg --purge sc-guest

if dpkg-query -W -f='${Status}' sc-guest 2>/dev/null | grep -qv 'not-installed'; then
    echo "FAIL: sc-guest is still known to dpkg after purge"
    exit 1
fi

left=0
while read -r path; do
    if [[ -e "$path" || -L "$path" ]]; then
        echo "FAIL: left behind after purge: $path"
        left=1
    fi
done < "$files"
if [[ $left -ne 0 ]]; then
    exit 1
fi

echo "lifecycle: ok"
