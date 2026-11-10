#!/bin/bash
# Installs this system's cloud-init, the one the package has to work with.
# Usage: setup-cloud-init.sh archive|proposed
#   archive   the version the system ships today, with its updates
#   proposed  the update the system is about to ship, when there is one
#
# Ubuntu releases cloud-init updates (often whole new versions) through
# <codename>-proposed before <codename>-updates. Debian stages fixes for a
# stable release in <codename>-proposed-updates.
set -euo pipefail

SOURCE="${1:?usage: setup-cloud-init.sh archive|proposed}"
export DEBIAN_FRONTEND=noninteractive

# shellcheck source=/dev/null
. /etc/os-release

if [[ "$SOURCE" == proposed ]]; then
    case "$ID" in
        ubuntu)
            case "$(dpkg --print-architecture)" in
                amd64|i386) mirror=http://archive.ubuntu.com/ubuntu ;;
                *) mirror=http://ports.ubuntu.com/ubuntu-ports ;;
            esac
            echo "deb $mirror ${VERSION_CODENAME}-proposed main" > /etc/apt/sources.list.d/proposed.list
            pin="a=${VERSION_CODENAME}-proposed"
            ;;
        debian)
            echo "deb http://deb.debian.org/debian ${VERSION_CODENAME}-proposed-updates main" > /etc/apt/sources.list.d/proposed.list
            pin="n=${VERSION_CODENAME}-proposed-updates"
            ;;
        *)
            echo "unsupported system: $ID" >&2
            exit 1
            ;;
    esac
    # Only cloud-init comes from the proposed pocket, and only when it has a
    # newer one. A pocket with nothing pending falls back to the archive.
    cat > /etc/apt/preferences.d/proposed-cloud-init <<EOF
Package: cloud-init
Pin: release $pin
Pin-Priority: 990
EOF
elif [[ "$SOURCE" != archive ]]; then
    echo "unknown source: $SOURCE" >&2
    exit 1
fi

apt-get update --quiet
apt-get install --yes --quiet --no-install-recommends cloud-init

echo "$PRETTY_NAME: cloud-init $(dpkg-query -W -f='${Version}' cloud-init) ($SOURCE)"
if [[ "$SOURCE" == proposed ]]; then
    apt-cache policy cloud-init
fi
