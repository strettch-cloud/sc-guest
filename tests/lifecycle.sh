#!/bin/bash
# Installs, removes and purges the package. Checks that cloud-init still
# works after a remove, which keeps the package's settings, and that a purge
# leaves none of its files behind. Runs as root in a throwaway container of
# each supported system, after setup-cloud-init.sh.
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

# The settings that stay still name the datasource. cloud-init has to find
# none and leave the network alone, rather than fail in every stage.
for kept in /etc/cloud/cloud.cfg.d/95_sc-guest.cfg /etc/cloud/ds-identify.cfg; do
    if [[ ! -f "$kept" ]]; then
        echo "FAIL: remove deleted $kept"
        exit 1
    fi
done
rm -rf /var/log/cloud-init.log /var/lib/cloud /run/cloud-init
cloud-init init --local
for expected in 'No local datasource found' 'network config is disabled by system_cfg'; do
    if ! grep -q "$expected" /var/log/cloud-init.log; then
        echo "FAIL: cloud-init's local stage didn't log: $expected"
        exit 1
    fi
done
if grep -q Traceback /var/log/cloud-init.log; then
    echo "FAIL: cloud-init's local stage logged a traceback"
    exit 1
fi
echo "after remove: cloud-init finds no datasource and leaves the network alone"

# dpkg, not apt: a package installed from a file isn't in apt's lists.
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
# Compiled by the package's install script, so not in its file list.
compiled="$(find /usr/lib/python3/dist-packages -path '*sc_guest*' -o -name 'DataSourceStrettchCloud*')"
if [[ -n "$compiled" ]]; then
    echo "FAIL: left behind after purge: $compiled"
    left=1
fi
if [[ $left -ne 0 ]]; then
    exit 1
fi

echo "lifecycle: ok"
