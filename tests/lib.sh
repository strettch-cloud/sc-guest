# shellcheck shell=bash
# Helpers for the tests that run sc-guest against the fake metadata service.
# Sourced by password.sh and report.sh, which use SC_GUEST, VERSION and
# WAIT_RC.
# shellcheck disable=SC2034

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_GUEST=/usr/lib/sc-guest/sc-guest
FAKE_DIR="$(mktemp -d)"
FAKE_PID=
export DEBIAN_FRONTEND=noninteractive

fail() {
    echo "FAIL: $*"
    exit 1
}

# Installs the package and the given tools, and puts the metadata service's
# address on the loopback, which needs the NET_ADMIN capability. Sets VERSION
# to the release tag the package was built from, which build-deb.sh puts in
# the file name.
prepare() {
    local deb="$1"
    shift
    VERSION="$(basename "$deb" | sed -n 's/^sc-guest_\(.*\)_all\.deb$/\1/p')"
    [[ -n "$VERSION" ]] || fail "no version in the file name $deb, want sc-guest_<tag>_all.deb"
    apt-get install --yes --quiet --quiet --no-install-recommends iproute2 "$@" "$deb" >/dev/null
    if ! ip -4 addr show dev lo | grep -q '169\.254\.169\.254/32'; then
        ip addr add 169.254.169.254/32 dev lo ||
            fail "can't add 169.254.169.254 to lo; run the container with --cap-add NET_ADMIN"
    fi
}

fake_config() {
    echo "$1" > "$FAKE_DIR/config.json"
}

fake_start() {
    python3 -I "$TESTS/fake-metadata.py" "$FAKE_DIR" &
    FAKE_PID=$!
    for _ in $(seq 50); do
        if python3 -c 'import socket; socket.create_connection(("169.254.169.254", 80), 1)' 2>/dev/null; then
            return
        fi
        sleep 0.1
    done
    fail "the fake metadata service didn't start"
}

fake_stop() {
    kill "$FAKE_PID"
    wait "$FAKE_PID" 2>/dev/null || true
}

# Prints the requests made since the last call, as sorted "METHOD PATH"
# lines, and fails if one lacked the Metadata-Flavor header or didn't send
# User-Agent: sc-guest/$VERSION.
fake_requests() {
    touch "$FAKE_DIR/requests.jsonl"
    python3 -I -c '
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1])]
for r in lines:
    if not r["flavor"]:
        sys.exit("request without the Metadata-Flavor header: %s %s" % (r["method"], r["path"]))
    if r["user_agent"] != "sc-guest/" + sys.argv[2]:
        sys.exit("request with User-Agent %r: %s %s" % (r["user_agent"], r["method"], r["path"]))
print("\n".join(sorted("%s %s" % (r["method"], r["path"]) for r in lines)))
' "$FAKE_DIR/requests.jsonl" "$VERSION" || fail "a request had the wrong headers"
    cat "$FAKE_DIR/requests.jsonl" >> "$FAKE_DIR/seen.jsonl"
    : > "$FAKE_DIR/requests.jsonl"
}

expect_requests() {
    local got
    got="$(fake_requests)"
    if [[ "$got" != "$1" ]]; then
        fail "requests: got [$got], want [$1]"
    fi
}

# Prints the body of the last request to a path.
last_body() {
    touch "$FAKE_DIR/seen.jsonl" "$FAKE_DIR/requests.jsonl"
    cat "$FAKE_DIR/seen.jsonl" "$FAKE_DIR/requests.jsonl" | python3 -I -c '
import json, sys
bodies = [r["body"] for r in map(json.loads, sys.stdin) if r["path"] == sys.argv[1]]
print(bodies[-1] if bodies else "")
' "$1"
}

# Prints one field of the last boot report as JSON.
report_field() {
    last_body /v1/report/boot | python3 -I -c 'import json, sys; print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))' "$1"
}

# Waits up to $2 seconds for the background process $1, and sets WAIT_RC to
# its exit code.
wait_for() {
    local waited=0
    while kill -0 "$1" 2>/dev/null; do
        if ((waited >= $2 * 10)); then
            fail "process $1 still running after $2 s"
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    WAIT_RC=0
    wait "$1" || WAIT_RC=$?
}

# A boot ends: /run is a tmpfs, so this boot's files go.
reboot_vm() {
    rm -rf /run/sc-guest
}
