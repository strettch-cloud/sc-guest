#!/bin/bash
# Runs this system's real cloud-init local and network stages for a VM
# created with an SSH key, then logs in to the container's own sshd as root
# with that key. Checks that the package's settings let root log in with a
# key, and that a customer's user data can still turn that off.
#
# Runs as root in a throwaway container, after setup-cloud-init.sh. It
# rewrites root's SSH keys and sshd's host keys, and runs sshd.
# Usage: root-login.sh <path to .deb>
set -euo pipefail

DEB="$(realpath "${1:?usage: root-login.sh <deb>}")"
export DEBIAN_FRONTEND=noninteractive

fail() {
    echo "FAIL: $*"
    exit 1
}

apt-get install --yes --quiet --quiet --no-install-recommends openssh-server openssh-client "$DEB" >/dev/null

# Sorts after the package's own settings, so these win. NoCloud stands in
# for the datasource, since disable_root comes from cloud.cfg.d either way.
# Only the modules that create the default user and write SSH keys run.
SETTINGS=/etc/cloud/cloud.cfg.d/99_zz-sc-guest-test.cfg
SEED=/var/lib/cloud/seed/nocloud
printf 'datasource_list: [ NoCloud ]\nnetwork: {config: disabled}\ncloud_init_modules: [ users_groups, ssh ]\n' > "$SETTINGS"

KEY="$(mktemp -d)/key"
ssh-keygen -q -t ed25519 -N '' -C sc-guest-test -f "$KEY"

# A new VM's first boot, with the key in its metadata and the given user data.
# Usage: first_boot <instance-id> <user data>
first_boot() {
    rm -rf /var/lib/cloud /run/cloud-init /var/log/cloud-init.log /root/.ssh /etc/ssh/ssh_host_*
    mkdir -p "$SEED"
    printf 'instance-id: %s\nlocal-hostname: root-login-test\npublic-keys:\n  - %s\n' "$1" "$(cat "$KEY.pub")" > "$SEED/meta-data"
    printf '%s\n' "$2" > "$SEED/user-data"
    cloud-init init --local >/dev/null 2>&1 || true
    cloud-init init >/dev/null 2>&1 || true
    grep -q "Running module ssh" /var/log/cloud-init.log || fail "cloud-init didn't run its ssh module"
    [[ -s /root/.ssh/authorized_keys ]] || fail "cloud-init wrote no key for root"
}

# Logs in as root with the key and prints what the session printed.
login_output() {
    mkdir -p /run/sshd
    /usr/sbin/sshd -p 2222 -o PidFile=/run/sc-guest-test-sshd.pid
    timeout 30 ssh -i "$KEY" -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 echo logged-in 2>&1 || true
    kill "$(cat /run/sc-guest-test-sshd.pid)"
}

echo "== a VM created with a key: root logs in with it"
first_boot iid-root-login-1 '#cloud-config'
grep -qx "$(cat "$KEY.pub")" /root/.ssh/authorized_keys ||
    fail "root's key has options: $(cat /root/.ssh/authorized_keys)"
out="$(login_output)"
[[ "$out" == logged-in ]] || fail "root login printed: $out"

echo "== the customer's user data sets disable_root: true, and it wins"
first_boot iid-root-login-2 $'#cloud-config\ndisable_root: true'
grep -q 'Please login as the user' /root/.ssh/authorized_keys ||
    fail "root's key has no forced command: $(cat /root/.ssh/authorized_keys)"

rm -f "$SETTINGS"
echo "root-login: ok"
