#!/bin/bash
# Checks the package's units the way systemd loads them at boot: they're
# enabled, valid, and no job is dropped to break an ordering cycle. systemd
# drops a unit in a cycle without failing the boot, so a cycle is easy to
# miss. Runs as root in a throwaway container after setup-cloud-init.sh.
# Usage: units.sh <path to .deb>
set -euo pipefail

DEB="$(realpath "${1:?usage: units.sh <deb>}")"
export DEBIAN_FRONTEND=noninteractive
apt-get install --yes --quiet --quiet --no-install-recommends systemd "$DEB" >/dev/null
echo "systemd $(dpkg-query -W -f='${Version}' systemd)"

UNITS=(sc-guest-password.service sc-guest-report.service)
WANTS=/etc/systemd/system/multi-user.target.wants

for unit in "${UNITS[@]}"; do
    if [[ ! -L "/etc/systemd/system/cloud-init.target.wants/$unit" ]]; then
        echo "FAIL: $unit isn't enabled"
        exit 1
    fi
done

out="$(cd /usr/lib/systemd/system && systemd-analyze verify "${UNITS[@]}" 2>&1)" || {
    echo "FAIL: systemd-analyze verify ${UNITS[*]}"
    echo "$out"
    exit 1
}
if [[ -n "$out" ]]; then
    echo "FAIL: systemd-analyze verify warns about the units:"
    echo "$out"
    exit 1
fi

# At boot, cloud-init's generator links cloud-init.target into
# multi-user.target when cloud-init is enabled.
mkdir -p "$WANTS"
ln -sf /usr/lib/systemd/system/cloud-init.target "$WANTS/cloud-init.target"

# Loads every unit the boot starts. Debian's graphical.target names a man
# page that isn't installed here, which makes verify exit 1, so only cycles
# count. A cycle prints the units in it, then the job systemd deleted, which
# can be any unit in the cycle.
cycles() {
    systemd-analyze verify default.target 2>&1 | grep -E 'ordering cycle|Found dependency on' || true
}

# A unit multi-user.target wants, ordered after cloud-final.service, must show
# up in a cycle, or this check can't see cycles on this system.
cat > /etc/systemd/system/sc-guest-cycle-check.service <<'EOF'
[Unit]
After=cloud-final.service
[Service]
Type=oneshot
ExecStart=/bin/true
EOF
ln -sf /etc/systemd/system/sc-guest-cycle-check.service "$WANTS/sc-guest-cycle-check.service"
if ! cycles | grep -q 'sc-guest-cycle-check.service'; then
    echo "FAIL: systemd-analyze didn't report the planted cycle"
    systemd-analyze verify default.target 2>&1 || true
    exit 1
fi
rm "$WANTS/sc-guest-cycle-check.service" /etc/systemd/system/sc-guest-cycle-check.service

found="$(cycles)"
if [[ -n "$found" ]]; then
    echo "FAIL: ordering cycles at boot:"
    echo "$found"
    exit 1
fi

echo "units: ok"
