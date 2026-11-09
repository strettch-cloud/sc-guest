#!/bin/bash
# Runs the password unit and the reporter against a fake metadata service:
# setting the password, the checks before the ack, the ack, keys-only VMs,
# sshd's drop-in precedence, retries and reboots.
#
# Runs as root in a throwaway container started with --cap-add NET_ADMIN,
# after setup-cloud-init.sh. It changes root's password and sshd's settings.
# cloud-init's files are written by hand here, as its local and network
# stages leave them; report.sh runs the real stages.
# Usage: password.sh <path to .deb>
set -euo pipefail

DEB="$(realpath "${1:?usage: password.sh <deb>}")"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

prepare "$DEB" openssh-server
fake_start
trap fake_stop EXIT

DROP_IN=/etc/ssh/sshd_config.d/55-sc-guest-password.conf
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id)"

# What cloud-init's local and network stages leave on a boot.
# Usage: cloud_init_ran <instance-id> [datasource as JSON]
cloud_init_ran() {
    local datasource='"DataSourceStrettchCloud [test]"'
    if [[ $# -gt 1 ]]; then datasource="$2"; fi
    mkdir -p /run/cloud-init /var/lib/cloud/data
    echo "$1" > /var/lib/cloud/data/instance-id
    cat > /run/cloud-init/status.json <<EOF
{"v1": {"datasource": $datasource,
        "init-local": {"errors": [], "finished": 1.0},
        "init": {"errors": [], "finished": 2.0}}}
EOF
}

# A new VM's first boot: no sshd host keys and no /run/sshd yet.
first_boot() {
    cloud_init_ran "$1"
    rm -f /etc/ssh/ssh_host_*
    rm -rf /run/sshd
    reboot_vm
}

password_unit() {
    local rc=0
    "$SC_GUEST" password || rc=$?
    if [[ $rc -ne $1 ]]; then
        fail "sc-guest password exited $rc, want $1"
    fi
}

reporter() {
    local rc=0
    "$SC_GUEST" report || rc=$?
    if [[ $rc -ne 0 ]]; then
        fail "sc-guest report exited $rc"
    fi
}

expect_state() {
    local got
    got="$(cat /var/lib/sc-guest/password.json 2>/dev/null || true)"
    if [[ "$got" != "$1" ]]; then
        fail "password state: got [$got], want [$1]"
    fi
}

root_password_is() {
    getent shadow root | cut -d: -f2 | PW="$1" perl -e 'my $h = <STDIN>; chomp $h; exit(crypt($ENV{PW}, $h) eq $h ? 0 : 1)'
}

# sshd's effective setting, as sshd reads its files.
sshd_setting() {
    local key
    key="$(mktemp -u)"
    ssh-keygen -q -t ed25519 -N '' -f "$key"
    mkdir -p /run/sshd
    sshd -T -h "$key" | awk -v k="$1" '$1 == k { print $2 }'
    rm -f "$key" "$key.pub"
}

# Ubuntu's cloud images turn password login off in this file.
mkdir -p /etc/ssh/sshd_config.d
echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/60-cloudimg-settings.conf

echo "== first boot with a pending password"
first_boot iid-1
fake_config '{"password": "first boot: pässwörd"}'
password_unit 0
expect_requests "GET /v1/password"
root_password_is "first boot: pässwörd" || fail "root's password wasn't set"
hash="$(getent shadow root | cut -d: -f2)"
[[ "${hash:0:3}" == "\$y\$" ]] || fail "root's hash isn't yescrypt"
[[ "$(grep -v '^#' "$DROP_IN")" == $'PasswordAuthentication yes\nPermitRootLogin yes' ]] || fail "drop-in: $(cat "$DROP_IN")"
[[ -d /run/sshd ]] || fail "/run/sshd wasn't created"
if compgen -G '/run/sc-guest-*' >/dev/null; then fail "the throwaway host key was left in /run"; fi
expect_state '{"instance-id": "iid-1", "state": "set"}'
reporter
expect_requests $'POST /v1/password/ack\nPOST /v1/report/boot'
[[ -z "$(last_body /v1/password/ack)" ]] || fail "the ack had a body"
[[ "$(report_field status)" == '"done"' ]] || fail "report status $(report_field status)"
[[ "$(report_field boot-id)" == "\"$BOOT_ID\"" ]] || fail "report boot-id $(report_field boot-id)"
[[ "$(report_field errors)" == '[]' ]] || fail "report errors $(report_field errors)"
expect_state '{"instance-id": "iid-1", "state": "acked"}'

echo "== sshd: our 55- file wins over the image's 60- file, a customer's 50- file wins over ours"
[[ "$(sshd_setting passwordauthentication)" == yes ]] || fail "55- lost to 60-cloudimg-settings.conf"
[[ "$(sshd_setting permitrootlogin)" == yes ]] || fail "PermitRootLogin isn't yes"
echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/50-cloud-init.conf
[[ "$(sshd_setting passwordauthentication)" == no ]] || fail "55- won over 50-cloud-init.conf"
rm /etc/ssh/sshd_config.d/50-cloud-init.conf

echo "== reboot: only a new boot report"
reboot_vm
password_unit 0
reporter
expect_requests "POST /v1/report/boot"

echo "== a VM made from a template of this one gets its own password; an ack that fails waits for a later boot"
first_boot iid-2
fake_config '{"password": "second VM", "ack_status": 503}'
password_unit 0
expect_requests "GET /v1/password"
root_password_is "second VM" || fail "the new instance's password wasn't set"
"$SC_GUEST" report &
pid=$!
for _ in $(seq 100); do
    if [[ -n "$(last_body /v1/report/boot)" ]] && grep -q password/ack "$FAKE_DIR/requests.jsonl"; then break; fi
    sleep 0.1
done
kill -0 "$pid" || fail "the reporter stopped instead of retrying the ack"
kill "$pid"
wait "$pid" || true
expect_state '{"instance-id": "iid-2", "state": "set"}'
fake_requests >/dev/null
fake_config '{"password": "second VM"}'
reboot_vm
password_unit 0
reporter
expect_requests $'POST /v1/password/ack\nPOST /v1/report/boot'
expect_state '{"instance-id": "iid-2", "state": "acked"}'

echo "== an ack answered 404 counts as delivered"
first_boot iid-3
fake_config '{"password": "third VM"}'
password_unit 0
fake_config '{"password": null}'
reporter
expect_requests $'GET /v1/password\nPOST /v1/password/ack\nPOST /v1/report/boot'
expect_state '{"instance-id": "iid-3", "state": "acked"}'

echo "== keys only: the password unit sets nothing and never asks again"
first_boot iid-4
rm -f "$DROP_IN"
hash_before="$(getent shadow root | cut -d: -f2)"
fake_config '{"password": null}'
password_unit 0
reporter
expect_requests $'GET /v1/password\nPOST /v1/report/boot'
expect_state '{"instance-id": "iid-4", "state": "none"}'
[[ ! -e "$DROP_IN" ]] || fail "the drop-in was written for a keys-only VM"
[[ "$(getent shadow root | cut -d: -f2)" == "$hash_before" ]] || fail "root's password changed"
[[ "$(sshd_setting passwordauthentication)" == no ]] || fail "password login is on for a keys-only VM"
reboot_vm
password_unit 0
reporter
expect_requests "POST /v1/report/boot"

echo "== a failed sshd check: no ack, and the boot report carries the error"
first_boot iid-5
echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/50-cloud-init.conf
fake_config '{"password": "fifth VM"}'
password_unit 1
grep -q 'sshd -T shows passwordauthentication no' /run/sc-guest/password-error || fail "error: $(cat /run/sc-guest/password-error)"
reporter
expect_requests $'GET /v1/password\nPOST /v1/report/boot'
[[ "$(report_field status)" == '"error"' ]] || fail "report status $(report_field status)"
[[ "$(report_field errors)" == '["password: sshd -T shows passwordauthentication no, not yes"]' ]] || fail "report errors $(report_field errors)"
expect_state '{"instance-id": "iid-4", "state": "none"}'
rm /etc/ssh/sshd_config.d/50-cloud-init.conf
echo "   the next boot tries again"
reboot_vm
password_unit 0
reporter
expect_requests $'GET /v1/password\nPOST /v1/password/ack\nPOST /v1/report/boot'
expect_state '{"instance-id": "iid-5", "state": "acked"}'

echo "== metadata service down: the password unit waits for it, the reporter retries"
first_boot iid-6
fake_stop
fake_config '{"password": "sixth VM"}'
"$SC_GUEST" password &
pid=$!
sleep 4
kill -0 "$pid" || fail "the password unit gave up while the metadata service was down"
fake_start
wait_for "$pid" 30
[[ $WAIT_RC -eq 0 ]] || fail "sc-guest password exited $WAIT_RC"
expect_state '{"instance-id": "iid-6", "state": "set"}'
fake_stop
"$SC_GUEST" report &
pid=$!
sleep 4
kill -0 "$pid" || fail "the reporter gave up while the metadata service was down"
fake_start
wait_for "$pid" 60
[[ $WAIT_RC -eq 0 ]] || fail "sc-guest report exited $WAIT_RC"
expect_requests $'GET /v1/password\nPOST /v1/password/ack\nPOST /v1/report/boot'
expect_state '{"instance-id": "iid-6", "state": "acked"}'

echo "== metadata service never answers: the password unit gives up as the datasource does, the next boot tries again"
first_boot iid-7
fake_stop
fake_config '{"password": "seventh VM"}'
# The datasource's 30 retries take minutes, so this run shortens them. If the
# unit didn't use the datasource's retries, it would never give up here.
python3 -I -c '
import runpy, sys
from sc_guest import metadata
metadata.RETRIES = 2
metadata._sleep = lambda seconds: None
sys.argv = [sys.argv[1], "password"]
runpy.run_path(sys.argv[0], run_name="__main__")
' "$SC_GUEST" &
pid=$!
wait_for "$pid" 30
[[ $WAIT_RC -eq 1 ]] || fail "sc-guest password exited $WAIT_RC, want 1"
grep -q '^password: GET http://169.254.169.254/v1/password failed 3 times' /run/sc-guest/password-error ||
    fail "error: $(cat /run/sc-guest/password-error)"
if root_password_is "seventh VM"; then fail "root's password was set"; fi
expect_state '{"instance-id": "iid-6", "state": "acked"}'
fake_start
reporter
expect_requests "POST /v1/report/boot"
[[ "$(report_field status)" == '"error"' ]] || fail "report status $(report_field status)"
report_field errors | grep -q '^\["password: GET http://169.254.169.254/v1/password failed 3 times' ||
    fail "report errors $(report_field errors)"
reboot_vm
password_unit 0
reporter
expect_requests $'GET /v1/password\nPOST /v1/password/ack\nPOST /v1/report/boot'
root_password_is "seventh VM" || fail "the next boot didn't set the password"
expect_state '{"instance-id": "iid-7", "state": "acked"}'

echo "== cloud-init found no datasource, or another one: the password unit does nothing"
for datasource in null '"DataSourceNoCloud [seed=/var/lib/cloud/seed/nocloud]"'; do
    cloud_init_ran iid-8 "$datasource"
    reboot_vm
    fake_config '{"password": "eighth VM"}'
    password_unit 0
    expect_requests ""
done

echo "password: ok"
