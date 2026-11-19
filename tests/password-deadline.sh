#!/bin/bash
# Flow 4, the password unit on every boot, with its 90-second limit on waiting
# for the metadata service and the customer's disable_root. Runs as root in a
# throwaway Debian container that has NET_ADMIN:
#
#   tests/password-deadline.sh <sc-guest .deb>
#
# It installs the package, serves a fake metadata service on 169.254.169.254,
# writes cloud-init's files itself and runs the installed `sc-guest password`.
# Most tests run the command in-process with a fake clock (fake-clock.py), so
# the real 90 s limit and the real waits take no time; the few that need real
# time shorten the limit in-process instead. /etc/shadow, chpasswd, systemctl,
# sshd and every directory the unit touches are restored after each test.

set -u

DEB=${1:?usage: $0 <sc-guest .deb>}
COMMAND=/usr/lib/sc-guest/sc-guest
STATUS=/run/cloud-init/status.json
INSTANCE_ID_FILE=/var/lib/cloud/data/instance-id
STATE=/var/lib/sc-guest/password.json
ERROR=/run/sc-guest/password-error
SSHD_FILE=/etc/ssh/sshd_config.d/55-sc-guest-password.conf
HASH_URL=http://169.254.169.254/v1/password/hash
USER_DATA_URL=http://169.254.169.254/v1/user-data
INSTANCE=i-0a1b2c3d
RUN_LIMIT=60

apt-get install -y "$DEB" || exit 1

WORK=$(mktemp -d)
ORIG=$WORK/orig
mkdir -p "$ORIG/bin"
BINARIES="/usr/sbin/chpasswd /usr/bin/systemctl /usr/sbin/sshd"
DIRECTORIES="/etc/ssh/sshd_config.d /var/lib/sc-guest /run/sc-guest /run/cloud-init /var/lib/cloud/data"

# --- the fake metadata service --------------------------------------------

# Answers each path from $WORK/answers/<path with _ for />.json: a list of
# answers used in turn, the last one repeated. A path without a file is a 404.
# Every request is logged to $WORK/requests.log, POST bodies to posts.log.
cat > "$WORK/fake-metadata.py" <<'EOF'
import http.server
import json
import sys
import threading
import time

WORK = sys.argv[1]
LOCK = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.answer()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with LOCK, open(f"{WORK}/posts.log", "ab") as f:
            f.write(self.path.encode() + b" " + body + b"\n")
        self.answer()

    def answer(self):
        request = f"{self.command} {self.path}"
        with LOCK:
            with open(f"{WORK}/requests.log", "a+") as f:
                f.seek(0)
                count = f.read().splitlines().count(request)
                f.write(request + "\n")
        name = self.path.removeprefix("/v1/").replace("/", "_")
        try:
            with open(f"{WORK}/answers/{name}.json") as f:
                answers = json.load(f)
        except OSError:
            answers = [{"status": 404, "body": '{"code": "not_found"}'}]
        answer = answers[min(count, len(answers) - 1)]
        self.close_connection = True
        try:
            self.send(answer)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def write(self, data):
        self.wfile.write(data)
        self.wfile.flush()

    def send(self, answer):
        if "close" in answer:
            return
        if "hang" in answer:
            time.sleep(answer["hang"])
            return
        body = answer.get("body", "").encode()
        if "body_file" in answer:
            with open(answer["body_file"], "rb") as f:
                body = f.read()
        status = answer.get("status", 200)
        head = (
            f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n"
        ).encode()
        if "trickle_headers" in answer:
            # The status line, then a header one byte at a time.
            every, until = answer["trickle_headers"]["every"], time.monotonic() + answer["trickle_headers"]["for"]
            self.write(f"HTTP/1.1 {status} X\r\nX-Slow: ".encode())
            while time.monotonic() < until:
                self.write(b"a")
                time.sleep(every)
            self.write(b"\r\n" + head.split(b"\r\n", 1)[1] + body)
        elif "trickle_body" in answer:
            # The headers, then the body a few bytes at a time; the
            # connection closes early if "for" runs out first.
            every, until = answer["trickle_body"]["every"], time.monotonic() + answer["trickle_body"]["for"]
            self.write(head)
            for i in range(0, len(body), 2):
                if time.monotonic() >= until:
                    return
                self.write(body[i : i + 2])
                time.sleep(every)
        else:
            self.write(head + body)


server = http.server.ThreadingHTTPServer(("169.254.169.254", 80), Handler)
server.daemon_threads = True
server.serve_forever()
EOF

# Runs `sc-guest password` in this process. "fake-clock": the metadata
# module's clock only moves when it waits, or by the seconds in
# $WORK/clock-jump; the waits go to $WORK/clock.json. "limit N": real time,
# with the unit's limit shortened to N seconds.
cat > "$WORK/fake-clock.py" <<'EOF'
import importlib.machinery
import importlib.util
import json
import sys

work, mode = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("sc_guest_command", "/usr/lib/sc-guest/sc-guest")
command = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(command)
from sc_guest import metadata

waits = []


def jumped():
    try:
        with open(f"{work}/clock-jump") as f:
            return float(f.read())
    except OSError:
        return 0.0


if mode == "fake-clock":
    metadata._monotonic = lambda: sum(waits) + jumped()
    metadata._sleep = waits.append
else:
    command.PASSWORD_DEADLINE = int(sys.argv[3])
sys.argv = ["sc-guest", "password"]
code = command.main()
with open(f"{work}/clock.json", "w") as f:
    json.dump({"waits": waits}, f)
sys.exit(code)
EOF

cat > "$WORK/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> $WORK/systemctl.log
case "\$1" in
  is-active) [ -e $WORK/sshd-running ] && exit 0; exit 3 ;;
  reload) [ -e $WORK/reload-fails ] && { echo "Job for ssh.service failed because the control process exited with error code."; exit 1; }; exit 0 ;;
esac
exit 0
EOF
chmod 755 "$WORK/systemctl"

# --- keeping one test's leftovers out of the next ---------------------------

cp -p /etc/shadow "$ORIG/shadow"
for binary in $BINARIES; do cp -p "$binary" "$ORIG/bin/"; done
for directory in $DIRECTORIES; do
  if [ -e "$directory" ]; then mkdir -p "$ORIG/dirs$(dirname "$directory")" && cp -a "$directory" "$ORIG/dirs$directory"; fi
done

restore_vm() {
  cp -p "$ORIG/shadow" /etc/shadow
  for binary in $BINARIES; do cp -p "$ORIG/bin/$(basename "$binary")" "$binary"; done
  for directory in $DIRECTORIES; do
    rm -rf "$directory"
    if [ -e "$ORIG/dirs$directory" ]; then cp -a "$ORIG/dirs$directory" "$directory"; fi
  done
  rm -rf "$WORK/answers" "$WORK/bodies"
  mkdir -p "$WORK/answers" "$WORK/bodies"
  : > "$WORK/requests.log"
  : > "$WORK/posts.log"
  rm -f "$WORK/clock-jump" "$WORK/clock.json" "$WORK/systemctl.log" "$WORK/sshd-running" "$WORK/reload-fails" "$WORK/output"
}

SERVER_PID=
finish() {
  restore_vm
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  ip addr del 169.254.169.254/32 dev lo 2>/dev/null
  rm -rf "$WORK"
}
trap finish EXIT

ip addr add 169.254.169.254/32 dev lo 2>/dev/null
restore_vm
python3 -I "$WORK/fake-metadata.py" "$WORK" &
SERVER_PID=$!
for _ in $(seq 50); do
  python3 -c 'import socket; socket.create_connection(("169.254.169.254", 80), 1)' 2>/dev/null && break
  sleep 0.1
done

# --- the situation a test starts from ---------------------------------------

HASH=$(perl -e 'print crypt("correct horse battery staple", q($6$Ux7mN2pQ$))')
ROOT_PASSWORD_BEFORE=$(awk -F: '$1 == "root" { print $2 }' /etc/shadow)

# cloud-init's local stage found the Strettch Cloud datasource and wrote the
# instance id; sshd isn't running (the fake systemctl says so).
cloud_init_found_strettch_cloud() {
  mkdir -p /run/cloud-init "$(dirname "$INSTANCE_ID_FILE")"
  echo '{"v1": {"datasource": "DataSourceStrettchCloud [seed=metadata]", "init-local": {"errors": []}, "init": {"errors": [], "finished": 1}}}' > "$STATUS"
  echo "${1:-$INSTANCE}" > "$INSTANCE_ID_FILE"
  cp -p "$WORK/systemctl" /usr/bin/systemctl
}

# answer <path> <answer as JSON>...
answer() {
  local path=$1 name
  shift
  name=$(echo "$path" | tr / _)
  (IFS=,; echo "[$*]") > "$WORK/answers/$name.json"
}

a_password_is_pending() {
  answer password/hash '{"status": 200, "body": "{\"hash\": \"'"$HASH"'\"}"}'
}

# the_user_data_is <file with the user data>
the_user_data_is() {
  answer user-data '{"status": 200, "body_file": "'"$1"'"}'
}

# user_data <text>: writes the text to a file and prints its path.
user_data() {
  local file
  file=$(mktemp -p "$WORK/bodies")
  printf '%s' "$1" > "$file"
  echo "$file"
}

UNAVAILABLE='{"status": 503, "body": "{\"code\": \"unavailable\"}"}'

# --- running the unit -------------------------------------------------------

RC=
run_unit() {
  timeout "$RUN_LIMIT" "$COMMAND" password > "$WORK/output" 2>&1
  RC=$?
}

run_unit_with_fake_clock() {
  timeout "$RUN_LIMIT" python3 -I "$WORK/fake-clock.py" "$WORK" fake-clock > "$WORK/output" 2>&1
  RC=$?
}

ELAPSED=
run_unit_with_limit() {
  local start
  start=$(date +%s.%N)
  timeout "$RUN_LIMIT" python3 -I "$WORK/fake-clock.py" "$WORK" limit "$1" > "$WORK/output" 2>&1
  RC=$?
  ELAPSED=$(python3 -c "print(round($(date +%s.%N) - $start, 2))")
}

run_report() {
  answer report/boot '{"status": 200, "body": "{}"}'
  answer password/ack '{"status": 200, "body": "{}"}'
  timeout "$RUN_LIMIT" "$COMMAND" report >> "$WORK/output" 2>&1
}

# --- what a test checks -------------------------------------------------------

requests_for() { grep -cx "GET /v1/$1" "$WORK/requests.log"; }
waits() { python3 -c 'import json, sys; print(" ".join(f"{w:g}" for w in json.load(open(sys.argv[1]))["waits"]))' "$WORK/clock.json"; }
total_wait() { python3 -c 'import json, sys; print(format(sum(json.load(open(sys.argv[1]))["waits"]), "g"))' "$WORK/clock.json"; }
root_password() { awk -F: '$1 == "root" { print $2 }' /etc/shadow; }
saved_state() { [ -e "$STATE" ] && python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["instance-id"], d["state"])' "$STATE"; }
boot_error() { [ -e "$ERROR" ] && cat "$ERROR"; }

FAILED=0
expect() {
  local what=$1 actual=$2 expected=$3
  if [ "$actual" != "$expected" ]; then
    echo "    ${CASE:-}expected $what to be: $expected"
    echo "                   but was: $actual"
    FAILED=1
  fi
}

expect_true() {
  local what=$1
  shift
  if ! "$@"; then
    echo "    expected $what"
    FAILED=1
  fi
}

expect_not() {
  local what=$1
  shift
  if "$@"; then
    echo "    expected $what"
    FAILED=1
  fi
}

expect_printed() {
  if ! grep -qxF -- "$1" "$WORK/output"; then
    echo "    expected the unit to print: $1"
    FAILED=1
  fi
}

# Nothing is set: root's password, the sshd file and the saved state are as
# they were before the unit ran.
expect_nothing_set() {
  expect "root's password" "$(root_password)" "$ROOT_PASSWORD_BEFORE"
  expect "the sshd file" "$([ -e "$SSHD_FILE" ] && echo written || echo absent)" absent
  expect "the saved state" "$(saved_state)" ""
}

expect_unit_failed_with() {
  expect "the unit's exit code" "$RC" 1
  expect "this boot's password error" "$(boot_error)" "$1"
}

sshd_file() { [ -e "$SSHD_FILE" ] && echo written || echo absent; }

PASSED=0
FAILURES=()
run_test() {
  local sentence=$1 test=$2
  restore_vm
  FAILED=0
  "$test"
  if [ "$FAILED" = 0 ]; then
    echo "ok   - $sentence"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL - $sentence"
    sed 's/^/    | /' "$WORK/output" 2>/dev/null | tail -20
    FAILURES+=("$sentence")
  fi
}

# --- the datasource, the instance id and the saved state ----------------------

another_datasource() {
  cloud_init_found_strettch_cloud
  echo '{"v1": {"datasource": "DataSourceNoCloud [seed=/dev/sr0]"}}' > "$STATUS"
  a_password_is_pending

  run_unit

  expect "the unit's exit code" "$RC" 0
  expect_printed "cloud-init's datasource is DataSourceNoCloud [seed=/dev/sr0], not DataSourceStrettchCloud: nothing to do"
  expect "requests to the metadata service" "$(wc -l < "$WORK/requests.log")" 0
  expect_nothing_set
}

no_datasource() {
  cloud_init_found_strettch_cloud
  rm "$STATUS"
  a_password_is_pending

  run_unit

  expect "the unit's exit code" "$RC" 0
  expect_printed "cloud-init's datasource is not found, not DataSourceStrettchCloud: nothing to do"
  expect "requests to the metadata service" "$(wc -l < "$WORK/requests.log")" 0
  expect_nothing_set
}

no_instance_id() {
  cloud_init_found_strettch_cloud
  rm "$INSTANCE_ID_FILE"
  a_password_is_pending

  run_unit

  expect_unit_failed_with "password: cloud-init found DataSourceStrettchCloud but wrote no /var/lib/cloud/data/instance-id"
  expect "requests to the metadata service" "$(wc -l < "$WORK/requests.log")" 0
  expect_nothing_set
}

handled_none() {
  cloud_init_found_strettch_cloud
  run_unit
  a_password_is_pending
  : > "$WORK/requests.log"

  run_unit

  expect "the unit's exit code" "$RC" 0
  expect_printed "the password was already handled for this instance (none)"
  expect "requests to the metadata service" "$(wc -l < "$WORK/requests.log")" 0
  expect "root's password" "$(root_password)" "$ROOT_PASSWORD_BEFORE"
}

handled_set() {
  cloud_init_found_strettch_cloud
  a_password_is_pending
  run_unit
  answer password/hash "$UNAVAILABLE"
  : > "$WORK/requests.log"

  run_unit

  expect "the unit's exit code" "$RC" 0
  expect_printed "the password was already handled for this instance (set)"
  expect "requests to the metadata service" "$(wc -l < "$WORK/requests.log")" 0
}

handled_acked() {
  cloud_init_found_strettch_cloud
  a_password_is_pending
  run_unit
  run_report
  answer password/hash "$UNAVAILABLE"
  : > "$WORK/requests.log"

  run_unit

  expect "the unit's exit code" "$RC" 0
  expect_printed "the password was already handled for this instance (acked)"
  expect "requests to the metadata service" "$(wc -l < "$WORK/requests.log")" 0
}

state_of_another_instance() {
  cloud_init_found_strettch_cloud i-template
  run_unit
  cloud_init_found_strettch_cloud "$INSTANCE"
  a_password_is_pending
  : > "$WORK/requests.log"

  run_unit

  expect "the unit's exit code" "$RC" 0
  expect "requests for the password hash" "$(requests_for password/hash)" 1
  expect "root's password" "$(root_password)" "$HASH"
  expect "the saved state" "$(saved_state)" "$INSTANCE set"
}

# --- the password hash, within 90 seconds ------------------------------------------

hash_gave_up_after_90_s() {
  cloud_init_found_strettch_cloud
  answer password/hash "$UNAVAILABLE"

  run_unit_with_fake_clock

  expect_unit_failed_with "password: gave up on GET $HASH_URL after 90 s, last with HTTP 503 unavailable"
  expect_nothing_set
}

hash_waits() {
  cloud_init_found_strettch_cloud
  answer password/hash "$UNAVAILABLE"

  run_unit_with_fake_clock

  expect "the waits between requests, in seconds" "$(waits)" "1 2 4 8 10 10 10 10 10 10 10 5"
  expect "requests for the password hash" "$(requests_for password/hash)" 12
}

hash_gave_up_dropped_connection() {
  cloud_init_found_strettch_cloud
  answer password/hash '{"close": true}'

  run_unit_with_fake_clock

  expect_unit_failed_with "password: gave up on GET $HASH_URL after 90 s, last with RemoteDisconnected('Remote end closed connection without response')"
  expect_nothing_set
}

hash_gave_up_in_the_report() {
  cloud_init_found_strettch_cloud
  answer password/hash "$UNAVAILABLE"
  run_unit_with_fake_clock

  run_report

  expect_true "the boot report to carry the error" grep -qF "\"password: gave up on GET $HASH_URL after 90 s, last with HTTP 503 unavailable\"" "$WORK/posts.log"
}

hash_asked_again_next_boot() {
  cloud_init_found_strettch_cloud
  answer password/hash "$UNAVAILABLE"
  run_unit_with_fake_clock
  a_password_is_pending
  : > "$WORK/requests.log"

  run_unit

  expect "requests for the password hash" "$(requests_for password/hash)" 1
  expect "the unit's exit code" "$RC" 0
  expect "root's password" "$(root_password)" "$HASH"
}

hash_answered_just_before_the_limit() {
  cloud_init_found_strettch_cloud
  answer password/hash "$UNAVAILABLE" "$UNAVAILABLE" "$UNAVAILABLE" "$UNAVAILABLE" "$UNAVAILABLE" "$UNAVAILABLE" \
    "$UNAVAILABLE" "$UNAVAILABLE" "$UNAVAILABLE" "$UNAVAILABLE" "$UNAVAILABLE" \
    '{"status": 200, "body": "{\"hash\": \"'"$HASH"'\"}"}'

  run_unit_with_fake_clock

  expect "the unit's exit code" "$RC" 0
  expect "the time waited before the 12th request, in seconds" "$(total_wait)" 85
  expect "root's password" "$(root_password)" "$HASH"
  expect "the saved state" "$(saved_state)" "$INSTANCE set"
}

body_trickle_cut_off() {
  local limit=3
  cloud_init_found_strettch_cloud
  answer password/hash '{"status": 200, "body": "{\"hash\": \"'"$HASH"'\"}'"$(printf '%*s' 103 '')"'", "trickle_body": {"every": 0.5, "for": 40}}'

  run_unit_with_limit "$limit"

  expect "the unit's exit code" "$RC" 1
  expect_true "the error to say it gave up after $limit s" grep -qF "password: gave up on GET $HASH_URL after $limit s, last with " "$ERROR"
  expect_true "the unit to stop within 1 s of the $limit s limit (took $ELAPSED s)" python3 -c "import sys; sys.exit(not $limit <= $ELAPSED < $limit + 1)"
  expect_nothing_set
}

never_answers() {
  local limit=3
  cloud_init_found_strettch_cloud
  answer password/hash '{"hang": 30}'

  run_unit_with_limit "$limit"

  expect "the unit's exit code" "$RC" 1
  expect_true "the error to say it gave up after $limit s" grep -qF "password: gave up on GET $HASH_URL after $limit s, last with " "$ERROR"
  expect_true "the unit to stop within 1 s of the $limit s limit (took $ELAPSED s)" python3 -c "import sys; sys.exit(not $limit <= $ELAPSED < $limit + 1)"
  expect_nothing_set
}

header_trickle_cut_off() {
  local limit=3
  cloud_init_found_strettch_cloud
  answer password/hash '{"status": 200, "body": "{\"hash\": \"'"$HASH"'\"}", "trickle_headers": {"every": 0.5, "for": 15}}'

  run_unit_with_limit "$limit"

  expect "the unit's exit code" "$RC" 1
  expect_true "the unit to stop within 1 s of the $limit s limit (took $ELAPSED s)" python3 -c "import sys; sys.exit(not $limit <= $ELAPSED < $limit + 1)"
  expect_nothing_set
}

error_body_trickle_cut_off() {
  local limit=3
  cloud_init_found_strettch_cloud
  answer password/hash '{"status": 503, "body": "{\"code\": \"unavailable\"}'"$(printf '%*s' 107 '')"'", "trickle_body": {"every": 0.5, "for": 15}}'

  run_unit_with_limit "$limit"

  expect "the unit's exit code" "$RC" 1
  expect_true "the unit to stop within 1 s of the $limit s limit (took $ELAPSED s)" python3 -c "import sys; sys.exit(not $limit <= $ELAPSED < $limit + 1)"
  expect_nothing_set
}

no_password_pending() {
  cloud_init_found_strettch_cloud

  run_unit

  expect "the unit's exit code" "$RC" 0
  expect "the saved state" "$(saved_state)" "$INSTANCE none"
  expect "root's password" "$(root_password)" "$ROOT_PASSWORD_BEFORE"
  expect "the sshd file" "$(sshd_file)" absent
  expect "requests for the user data" "$(requests_for user-data)" 0
}

# --- the hash checks -----------------------------------------------------------

hash_check() {
  local body=$1 error=$2
  cloud_init_found_strettch_cloud
  answer password/hash "{\"status\": 200, \"body\": $(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$body")}"

  run_unit

  expect_unit_failed_with "$error"
  expect_nothing_set
  expect "requests for the user data" "$(requests_for user-data)" 0
}

hash_not_json() { hash_check 'not json' "password: GET /v1/password/hash answered 200 without a hash"; }
hash_missing() { hash_check '{"digest": "x"}' "password: GET /v1/password/hash answered 200 without a hash"; }

hash_not_crypt() {
  hash_check '{"hash": "hunter2-plain-text"}' "password: GET /v1/password/hash answered 200 with something that isn't a crypt(3) hash"
  expect_not "the answer to stay out of the unit's output" grep -qF hunter2 "$WORK/output"
}

hash_cut_off_digest() {
  # shellcheck disable=SC2016 # the $ belongs to the hash
  hash_check '{"hash": "$6$Ux7mN2pQ$tooshort"}' "password: GET /v1/password/hash answered 200 with a hash this system can't check a password against"
}

hash_unknown_method() {
  # shellcheck disable=SC2016 # the $ belongs to the hash
  hash_check '{"hash": "$99$Ux7mN2pQ$abcdefghijklmnopqrstuvwxyz0123456789"}' "password: GET /v1/password/hash answered 200 with a hash this system can't check a password against"
}

# --- the user data, within the same 90 seconds ------------------------------------

user_data_gave_up() {
  cloud_init_found_strettch_cloud
  a_password_is_pending
  answer user-data "$UNAVAILABLE"

  run_unit_with_fake_clock

  expect_unit_failed_with "password: gave up on GET $USER_DATA_URL after 90 s, last with HTTP 503 unavailable"
  expect_nothing_set
}

user_data_gets_what_is_left() {
  cloud_init_found_strettch_cloud
  answer password/hash "$UNAVAILABLE" "$UNAVAILABLE" "$UNAVAILABLE" "$UNAVAILABLE" \
    '{"status": 200, "body": "{\"hash\": \"'"$HASH"'\"}"}'
  answer user-data "$UNAVAILABLE"

  run_unit_with_fake_clock

  expect_unit_failed_with "password: gave up on GET $USER_DATA_URL after 90 s, last with HTTP 503 unavailable"
  expect "the waits for the hash, then for the user data" "$(waits)" "1 2 4 8 1 2 4 8 10 10 10 10 10 10"
  expect "the total wait, in seconds" "$(total_wait)" 90
  expect_nothing_set
}

user_data_404() {
  cloud_init_found_strettch_cloud
  a_password_is_pending

  run_unit

  expect "the unit's exit code" "$RC" 0
  expect "root's password" "$(root_password)" "$HASH"
  expect "the sshd file" "$(sshd_file)" written
  expect "the saved state" "$(saved_state)" "$INSTANCE set"
}

# disable_root_test <user data file> <written|absent>: the whole unit with that
# user data, and whether the sshd file allowing root password login is written.
disable_root_case() {
  local file=$1 expected=$2
  cloud_init_found_strettch_cloud
  a_password_is_pending
  the_user_data_is "$file"

  run_unit

  expect "the unit's exit code" "$RC" 0
  expect "root's password" "$(root_password)" "$HASH"
  expect "the saved state" "$(saved_state)" "$INSTANCE set"
  expect "the sshd file" "$(sshd_file)" "$expected"
}

disable_root_true() {
  disable_root_case "$(user_data $'#cloud-config\ndisable_root: true\n')" absent
  expect_printed "set root's password; the user data sets disable_root, so root can't log in over SSH"
}

disable_root_true_spellings() {
  local value
  for value in true True yes on 1 '"true"' '"yes"' '"on"' '"1"' '"ON"'; do
    restore_vm
    CASE="(disable_root: $value) "
    disable_root_case "$(user_data "#cloud-config
disable_root: $value
")" absent
  done
  CASE=
}

disable_root_true_skips_sshd() {
  cloud_init_found_strettch_cloud
  echo 'NotAnSshdOption yes' > /etc/ssh/sshd_config.d/10-broken.conf
  touch "$WORK/sshd-running"
  echo reload-fails > "$WORK/reload-fails"
  a_password_is_pending
  the_user_data_is "$(user_data $'#cloud-config\ndisable_root: true\n')"

  run_unit

  expect "the unit's exit code" "$RC" 0
  expect "systemctl calls" "$(cat "$WORK/systemctl.log" 2>/dev/null)" ""
  expect "the saved state" "$(saved_state)" "$INSTANCE set"
}

disable_root_keeps_existing_file() {
  local before='# from an earlier boot
PasswordAuthentication yes
PermitRootLogin yes'
  mkdir -p "$(dirname "$SSHD_FILE")"
  echo "$before" > "$SSHD_FILE"
  disable_root_case "$(user_data $'#cloud-config\ndisable_root: true\n')" written
  expect "the sshd file's text" "$(cat "$SSHD_FILE")" "$before"
}

disable_root_false() { disable_root_case "$(user_data $'#cloud-config\ndisable_root: false\n')" written; }
disable_root_absent() { disable_root_case "$(user_data $'#cloud-config\nhostname: web-1\n')" written; }
disable_root_other_value() { disable_root_case "$(user_data $'#cloud-config\ndisable_root: maybe\n')" written; }

mime() {
  python3 - "$@" <<'EOF'
import sys
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

message = MIMEMultipart()
for i in range(1, len(sys.argv), 2):
    message.attach(MIMEText(sys.argv[i + 1], sys.argv[i]))
sys.stdout.write(message.as_string())
EOF
}

disable_root_last_part_true() {
  disable_root_case "$(user_data "$(mime cloud-config $'#cloud-config\ndisable_root: false\n' cloud-config $'#cloud-config\ndisable_root: true\n')")" absent
}

disable_root_last_part_false() {
  disable_root_case "$(user_data "$(mime cloud-config $'#cloud-config\ndisable_root: true\n' cloud-config $'#cloud-config\ndisable_root: false\n')")" written
}

disable_root_last_part_silent() {
  disable_root_case "$(user_data "$(mime cloud-config $'#cloud-config\ndisable_root: true\n' cloud-config $'#cloud-config\nhostname: web-1\n')")" absent
}

disable_root_mime_with_script() {
  disable_root_case "$(user_data "$(mime x-shellscript $'#!/bin/sh\necho hi\n' cloud-config $'disable_root: true\n')")" absent
}

disable_root_gzip() {
  local file
  file=$(mktemp -p "$WORK/bodies")
  printf '#cloud-config\ndisable_root: true\n' | gzip > "$file"
  disable_root_case "$file" absent
}

disable_root_gzip_mime() {
  local file
  file=$(mktemp -p "$WORK/bodies")
  mime cloud-config $'#cloud-config\ndisable_root: true\n' | gzip > "$file"
  disable_root_case "$file" absent
}

disable_root_jinja() {
  disable_root_case "$(user_data $'## template: jinja\n#cloud-config\ndisable_root: true\n')" written
}

disable_root_include() {
  disable_root_case "$(user_data $'#include\nhttp://example.com/cloud-config\n')" written
}

disable_root_bad_yaml() {
  disable_root_case "$(user_data $'#cloud-config\ndisable_root: [true\n')" written
}

disable_root_script() {
  disable_root_case "$(user_data $'#!/bin/sh\necho disable_root: true\n')" written
}

disable_root_binary() {
  local file
  file=$(mktemp -p "$WORK/bodies")
  printf '\x1f\x8b\x08\x00garbage-that-is-not-gzip' > "$file"
  disable_root_case "$file" written
}

disable_root_deep_yaml() {
  local file
  file=$(mktemp -p "$WORK/bodies")
  { printf '#cloud-config\nhostname: '; head -c 20000 /dev/zero | tr '\0' '['; } > "$file"
  disable_root_case "$file" written
}

# --- setting the password and sshd -------------------------------------------------

fake_chpasswd() {
  printf '#!/bin/sh\n%s\n' "$1" > /usr/sbin/chpasswd
}

chpasswd_fails() {
  cloud_init_found_strettch_cloud
  a_password_is_pending
  fake_chpasswd 'cat >/dev/null; echo "chpasswd: cannot lock /etc/shadow; try again later."; exit 1'

  run_unit

  expect_unit_failed_with "password: chpasswd -e failed: chpasswd: cannot lock /etc/shadow; try again later."
  expect_nothing_set
}

shadow_not_the_hash() {
  cloud_init_found_strettch_cloud
  a_password_is_pending
  fake_chpasswd 'cat >/dev/null; exit 0'

  run_unit

  expect_unit_failed_with "password: root's entry in /etc/shadow isn't the password hash after chpasswd"
  expect "the saved state" "$(saved_state)" ""
  expect "the sshd file" "$(sshd_file)" absent
}

sshd_missing() {
  cloud_init_found_strettch_cloud
  a_password_is_pending
  rm /usr/sbin/sshd

  run_unit

  expect_unit_failed_with "password: sshd or ssh-keygen isn't installed"
  expect "root's password" "$(root_password)" "$HASH"
  expect "the sshd file" "$(sshd_file)" written
  expect "the saved state" "$(saved_state)" ""
}

sshd_check_fails() {
  cloud_init_found_strettch_cloud
  a_password_is_pending
  echo 'NotAnSshdOption yes' > /etc/ssh/sshd_config.d/10-broken.conf

  run_unit

  expect "the unit's exit code" "$RC" 1
  expect_true "the error to start with 'password: sshd -T failed: '" grep -q '^password: sshd -T failed: ' "$ERROR"
  expect "root's password" "$(root_password)" "$HASH"
  expect "the sshd file" "$(sshd_file)" written
  expect "the saved state" "$(saved_state)" ""
}

customer_turns_password_login_off() {
  cloud_init_found_strettch_cloud
  a_password_is_pending
  echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/50-cloud-init.conf

  run_unit

  expect_unit_failed_with "password: sshd -T shows passwordauthentication no, not yes"
  expect "root's password" "$(root_password)" "$HASH"
  expect "the sshd file" "$(sshd_file)" written
  expect "the saved state" "$(saved_state)" ""
}

sshd_not_running() {
  cloud_init_found_strettch_cloud
  a_password_is_pending

  run_unit

  expect "the unit's exit code" "$RC" 0
  expect "the saved state" "$(saved_state)" "$INSTANCE set"
  expect_not "sshd not to be reloaded" grep -q reload "$WORK/systemctl.log"
  expect_printed "set root's password and allowed password login over SSH"
}

reload_fails() {
  cloud_init_found_strettch_cloud
  a_password_is_pending
  touch "$WORK/sshd-running" "$WORK/reload-fails"

  run_unit

  expect_unit_failed_with "password: reloading sshd failed: Job for ssh.service failed because the control process exited with error code."
  expect "root's password" "$(root_password)" "$HASH"
  expect "the sshd file" "$(sshd_file)" written
  expect "the saved state" "$(saved_state)" ""
}

reload_works() {
  cloud_init_found_strettch_cloud
  a_password_is_pending
  touch "$WORK/sshd-running"

  run_unit

  expect "the unit's exit code" "$RC" 0
  expect_true "sshd to be reloaded" grep -qx "reload ssh.service" "$WORK/systemctl.log"
  expect "root's password" "$(root_password)" "$HASH"
  expect "the sshd file's text" "$(cat "$SSHD_FILE")" $'# Written by sc-guest: this VM was created with a root password.\nPasswordAuthentication yes\nPermitRootLogin yes'
  expect "the saved state" "$(saved_state)" "$INSTANCE set"
}

limit_does_not_cut_off_setting() {
  cloud_init_found_strettch_cloud
  a_password_is_pending
  touch "$WORK/sshd-running"
  fake_chpasswd "echo 1000 > $WORK/clock-jump; exec $ORIG/bin/chpasswd \"\$@\""

  run_unit_with_fake_clock

  expect "the unit's exit code" "$RC" 0
  expect "root's password" "$(root_password)" "$HASH"
  expect_true "sshd to be reloaded" grep -qx "reload ssh.service" "$WORK/systemctl.log"
  expect "the saved state" "$(saved_state)" "$INSTANCE set"
}

# --- the tests ---------------------------------------------------------------------

echo
echo "Flow 4: the password unit, every boot"
run_test "with another datasource, the unit sets nothing, sends no request and succeeds" another_datasource
run_test "with no datasource found, the unit sets nothing, sends no request and succeeds" no_datasource
run_test "with no instance id, the unit sets nothing and fails with the instance id error" no_instance_id
run_test "once the state is 'none' for this instance, a later boot sends no request" handled_none
run_test "once the state is 'set' for this instance, a later boot sends no request" handled_set
run_test "once the state is 'acked' for this instance, a later boot sends no request" handled_acked
run_test "a state saved for another instance id doesn't stop the unit asking and setting the password" state_of_another_instance
run_test "a hash that never comes within 90 s sets nothing and fails with 'gave up ... after 90 s, last with HTTP 503 unavailable'" hash_gave_up_after_90_s
run_test "the waits between hash requests are 1, 2, 4, 8, then 10 s, the last shortened to end at 90 s: 12 requests, never 31" hash_waits
run_test "a dropped connection is the reason given when the hash never comes within 90 s" hash_gave_up_dropped_connection
run_test "the boot report carries the 'gave up after 90 s' error" hash_gave_up_in_the_report
run_test "after giving up on the hash, the next boot asks again" hash_asked_again_next_boot
run_test "a hash answered on the 12th request, 85 s in, is still set" hash_answered_just_before_the_limit
run_test "a hash answer arriving a few bytes at a time is cut off at the limit (real time, 3 s limit)" body_trickle_cut_off
run_test "a metadata service that never answers is given up on at the limit (real time, 3 s limit)" never_answers
run_test "an answer whose headers arrive a few bytes at a time is cut off at the limit (real time, 3 s limit)" header_trickle_cut_off
run_test "an error answer whose body arrives a few bytes at a time is cut off at the limit (real time, 3 s limit)" error_body_trickle_cut_off
run_test "with no password pending, nothing is set, 'none' is saved, and the user data isn't asked for" no_password_pending
run_test "a 200 that isn't JSON sets nothing and fails with 'answered 200 without a hash'" hash_not_json
run_test "a 200 without a hash sets nothing and fails with 'answered 200 without a hash'" hash_missing
run_test "a hash that isn't crypt(3) sets nothing and fails without the answer in the error" hash_not_crypt
run_test "a hash with a cut-off digest sets nothing and fails with 'can't check a password against'" hash_cut_off_digest
run_test "a hash with an unknown method sets nothing and fails with 'can't check a password against'" hash_unknown_method
run_test "user data that never comes within 90 s sets nothing and fails with 'gave up on GET .../user-data after 90 s'" user_data_gave_up
run_test "the user data gets only what is left of the same 90 s" user_data_gets_what_is_left
run_test "with no user data (404), the password is set and the sshd file written" user_data_404
run_test "disable_root: true sets the password, writes no sshd file, saves 'set' and succeeds" disable_root_true
run_test "disable_root set to true, yes, on or 1, as YAML values or quoted text in any case, writes no sshd file" disable_root_true_spellings
run_test "with disable_root true, sshd is neither checked nor reloaded" disable_root_true_skips_sshd
run_test "with disable_root true, an sshd file already on disk is left alone" disable_root_keeps_existing_file
run_test "disable_root: false writes the sshd file" disable_root_false
run_test "cloud-config without disable_root writes the sshd file" disable_root_absent
run_test "disable_root set to something other than true, yes, on or 1 writes the sshd file" disable_root_other_value
run_test "with several MIME parts, a last part setting disable_root true wins" disable_root_last_part_true
run_test "with several MIME parts, a last part setting disable_root false wins" disable_root_last_part_false
run_test "a later MIME part that doesn't set disable_root leaves an earlier true in force" disable_root_last_part_silent
run_test "a text/cloud-config MIME part without the #cloud-config line is read" disable_root_mime_with_script
run_test "gzipped cloud-config is read" disable_root_gzip
run_test "gzipped MIME is read" disable_root_gzip_mime
run_test "Jinja user data counts as not setting disable_root" disable_root_jinja
run_test "#include user data counts as not setting disable_root" disable_root_include
run_test "cloud-config that isn't valid YAML counts as not setting disable_root" disable_root_bad_yaml
run_test "a shell script counts as not setting disable_root" disable_root_script
run_test "unreadable gzip counts as not setting disable_root" disable_root_binary
run_test "cloud-config nested too deeply to read counts as not setting disable_root" disable_root_deep_yaml
run_test "a failing chpasswd sets nothing and fails with chpasswd's output" chpasswd_fails
run_test "a shadow entry that isn't the hash after chpasswd fails and saves no state" shadow_not_the_hash
run_test "without sshd, the password stays set, the sshd file stays, no state is saved and the unit fails" sshd_missing
run_test "a failing sshd -T leaves the password and sshd file, saves no state and fails" sshd_check_fails
run_test "a customer's PasswordAuthentication no leaves the password and sshd file, saves no state and fails" customer_turns_password_login_off
run_test "with sshd not running, the password is set, 'set' is saved and sshd isn't reloaded" sshd_not_running
run_test "a failing sshd reload leaves the password and sshd file, saves no state and fails" reload_fails
run_test "a working sshd reload sets the password, writes the sshd file and saves 'set'" reload_works
run_test "the 90 s limit doesn't cut off chpasswd or the sshd check and reload" limit_does_not_cut_off_setting

restore_vm
for binary in $BINARIES; do
  cmp -s "$binary" "$ORIG/bin/$(basename "$binary")" || { echo "not restored: $binary"; FAILURES+=("restore $binary"); }
done
cmp -s /etc/shadow "$ORIG/shadow" || { echo "not restored: /etc/shadow"; FAILURES+=("restore /etc/shadow"); }

echo
echo "$PASSED passed, ${#FAILURES[@]} failed"
for failure in "${FAILURES[@]}"; do echo "  FAIL - $failure"; done
[ "${#FAILURES[@]}" = 0 ]
