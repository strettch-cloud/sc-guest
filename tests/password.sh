#!/bin/bash
# Runs the password unit and the reporter against a fake metadata service:
# setting the password from its hash, logging in with it over SSH, the checks
# before the ack, the ack, keys-only VMs, sshd's drop-in precedence, retries
# and reboots.
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

# The SHA-512 crypt hash of a password, as the metadata service serves it,
# made with this system's libcrypt.
# Usage: hash_of <password> <salt>
hash_of() {
    PW="$1" perl -e 'print crypt($ENV{PW}, "\$6\$rounds=100000\$$ARGV[0]\$")' "$2"
}

# Serves the hash of a password as the pending one, with any other settings.
# Usage: pending <password> <salt> [more JSON members]
pending() {
    fake_config "{\"password_hash\": \"$(hash_of "$1" "$2")\"${3:+, $3}}"
}

# Logs in to the container's own sshd as root with a typed password, as a
# customer does, and prints what the session printed.
password_login_output() {
    local askpass
    askpass="$(mktemp)"
    printf '#!/bin/sh\nprintf "%%s\\n" "$TYPED_PASSWORD"\n' > "$askpass"
    chmod +x "$askpass"
    ssh-keygen -A >/dev/null
    mkdir -p /run/sshd
    /usr/sbin/sshd -p 2222 -o PidFile=/run/sc-guest-test-sshd.pid
    TYPED_PASSWORD="$1" SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
        timeout 30 setsid -w ssh -n -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
        -o LogLevel=ERROR root@127.0.0.1 echo logged-in 2>&1 || true
    kill "$(cat /run/sc-guest-test-sshd.pid)"
    rm -f "$askpass"
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
pending "first boot: pässwörd" Ab3dEf6hIj9lMn0p
password_unit 0
expect_requests "GET /v1/password/hash"
[[ "$(getent shadow root | cut -d: -f2)" == "$(hash_of "first boot: pässwörd" Ab3dEf6hIj9lMn0p)" ]] ||
    fail "root's entry in /etc/shadow isn't the hash"
root_password_is "first boot: pässwörd" || fail "root's password wasn't set"
[[ "$(grep -v '^#' "$DROP_IN")" == $'PasswordAuthentication yes\nPermitRootLogin yes' ]] || fail "drop-in: $(cat "$DROP_IN")"
[[ -d /run/sshd ]] || fail "/run/sshd wasn't created"
if compgen -G '/run/sc-guest-*' >/dev/null; then fail "the throwaway host key was left in /run"; fi
expect_state '{"instance-id": "iid-1", "state": "set"}'
reporter
expect_requests $'POST /v1/password/ack\nPOST /v1/report/boot'
[[ -z "$(last_body /v1/password/ack)" ]] || fail "the ack had a body"
[[ "$(report_field status)" == '"done"' ]] || fail "report status $(report_field status)"
[[ "$(report_field boot-id)" == "\"$BOOT_ID\"" ]] || fail "report boot-id $(report_field boot-id)"
[[ "$(report_field version)" == "\"$VERSION\"" ]] || fail "report version $(report_field version), want \"$VERSION\""
[[ "$(report_field errors)" == '[]' ]] || fail "report errors $(report_field errors)"
expect_state '{"instance-id": "iid-1", "state": "acked"}'

echo "== root logs in over SSH with the typed password, and not with another"
out="$(password_login_output "first boot: pässwörd")"
[[ "$out" == logged-in ]] || fail "login with the password printed: $out"
out="$(password_login_output "first boot: passwort")"
[[ "$out" != *logged-in* ]] || fail "a wrong password logged in"

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
pending "second VM" second.VM.salt.. '"ack_status": 503'
password_unit 0
expect_requests "GET /v1/password/hash"
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
pending "second VM" second.VM.salt..
reboot_vm
password_unit 0
reporter
expect_requests $'POST /v1/password/ack\nPOST /v1/report/boot'
expect_state '{"instance-id": "iid-2", "state": "acked"}'

echo "== an ack answered 404 counts as delivered"
first_boot iid-3
pending "third VM" third.VM.salt...
password_unit 0
fake_config '{"password_hash": null}'
reporter
expect_requests $'GET /v1/password/hash\nPOST /v1/password/ack\nPOST /v1/report/boot'
expect_state '{"instance-id": "iid-3", "state": "acked"}'

echo "== keys only: the password unit sets nothing and never asks again"
first_boot iid-4
rm -f "$DROP_IN"
hash_before="$(getent shadow root | cut -d: -f2)"
fake_config '{"password_hash": null}'
password_unit 0
reporter
expect_requests $'GET /v1/password/hash\nPOST /v1/report/boot'
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
pending "fifth VM" fifth.VM.salt...
password_unit 1
grep -q 'sshd -T shows passwordauthentication no' /run/sc-guest/password-error || fail "error: $(cat /run/sc-guest/password-error)"
reporter
expect_requests $'GET /v1/password/hash\nPOST /v1/report/boot'
[[ "$(report_field status)" == '"error"' ]] || fail "report status $(report_field status)"
[[ "$(report_field errors)" == '["password: sshd -T shows passwordauthentication no, not yes"]' ]] || fail "report errors $(report_field errors)"
expect_state '{"instance-id": "iid-4", "state": "none"}'
rm /etc/ssh/sshd_config.d/50-cloud-init.conf
echo "   the next boot tries again"
reboot_vm
password_unit 0
reporter
expect_requests $'GET /v1/password/hash\nPOST /v1/password/ack\nPOST /v1/report/boot'
expect_state '{"instance-id": "iid-5", "state": "acked"}'

echo "== an answer that isn't a hash: nothing is set, no ack, and the error doesn't hold the answer"
first_boot iid-5b
hash_before="$(getent shadow root | cut -d: -f2)"
fake_config '{"password_hash": "the password itself"}'
password_unit 1
grep -qx "password: GET /v1/password/hash answered 200 with something that isn't a crypt(3) hash" \
    /run/sc-guest/password-error || fail "error: $(cat /run/sc-guest/password-error)"
reporter
expect_requests $'GET /v1/password/hash\nPOST /v1/report/boot'
last_body /v1/report/boot | grep -q "the password itself" && fail "the boot report holds the answer"
[[ "$(getent shadow root | cut -d: -f2)" == "$hash_before" ]] || fail "root's password changed"
expect_state '{"instance-id": "iid-5", "state": "acked"}'

echo "== metadata service down: the password unit waits for it, the reporter retries"
first_boot iid-6
fake_stop
pending "sixth VM" sixth.VM.salt...
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
expect_requests $'GET /v1/password/hash\nPOST /v1/password/ack\nPOST /v1/report/boot'
expect_state '{"instance-id": "iid-6", "state": "acked"}'

echo "== metadata service never answers: the password unit gives up as the datasource does, the next boot tries again"
first_boot iid-7
fake_stop
pending "seventh VM" seventh.VM.salt.
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
grep -q '^password: GET http://169.254.169.254/v1/password/hash failed 3 times' /run/sc-guest/password-error ||
    fail "error: $(cat /run/sc-guest/password-error)"
if root_password_is "seventh VM"; then fail "root's password was set"; fi
expect_state '{"instance-id": "iid-6", "state": "acked"}'
fake_start
reporter
expect_requests "POST /v1/report/boot"
[[ "$(report_field status)" == '"error"' ]] || fail "report status $(report_field status)"
report_field errors | grep -q '^\["password: GET http://169.254.169.254/v1/password/hash failed 3 times' ||
    fail "report errors $(report_field errors)"
reboot_vm
password_unit 0
reporter
expect_requests $'GET /v1/password/hash\nPOST /v1/password/ack\nPOST /v1/report/boot'
root_password_is "seventh VM" || fail "the next boot didn't set the password"
expect_state '{"instance-id": "iid-7", "state": "acked"}'

echo "== a service without the hash route: the password unit retries, never takes it as no password"
first_boot iid-7b
pending "seventh VM b" seventh.VM.salt2 '"no_hash_route": true'
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
grep -q '^password: GET http://169.254.169.254/v1/password/hash failed 3 times, last with HTTP 404 NOT_FOUND' \
    /run/sc-guest/password-error || fail "error: $(cat /run/sc-guest/password-error)"
expect_requests $'GET /v1/password/hash\nGET /v1/password/hash\nGET /v1/password/hash'
expect_state '{"instance-id": "iid-7", "state": "acked"}'
echo "   the next boot, with the route, sets the password"
pending "seventh VM b" seventh.VM.salt2
reboot_vm
password_unit 0
reporter
expect_requests $'GET /v1/password/hash\nPOST /v1/password/ack\nPOST /v1/report/boot'
root_password_is "seventh VM b" || fail "the next boot didn't set the password"
expect_state '{"instance-id": "iid-7b", "state": "acked"}'

echo "== cloud-init found no datasource, or another one: the password unit does nothing"
for datasource in null '"DataSourceNoCloud [seed=/var/lib/cloud/seed/nocloud]"'; do
    cloud_init_ran iid-8 "$datasource"
    reboot_vm
    pending "eighth VM" eighth.VM.salt..
    password_unit 0
    expect_requests ""
done

echo "password: ok"
