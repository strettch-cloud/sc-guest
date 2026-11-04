#!/bin/bash
# Runs this system's real cloud-init local and network stages, then the
# reporter against a fake metadata service, and checks what the boot report
# says: done when the datasource loads, even when it logged warnings first or
# a customer's bootcmd fails, and error with cloud-init's reason when the
# datasource can't load.
#
# Runs as root in a throwaway container started with --cap-add NET_ADMIN,
# after setup-cloud-init.sh.
# Usage: report.sh <path to .deb>
set -euo pipefail

DEB="$(realpath "${1:?usage: report.sh <deb>}")"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

prepare "$DEB"
fake_start
trap fake_stop EXIT
fake_config '{"password": null}'

# Sorts after the package's own settings and Ubuntu's 90_dpkg.cfg, so these
# win. Only bootcmd runs in the network stage, so a container can run it.
SETTINGS=/etc/cloud/cloud.cfg.d/99_zz-sc-guest-test.cfg
# Test-only datasources: one loads after logging a warning, as a datasource
# does when it had to retry, and one fails.
WARNS=/usr/lib/python3/dist-packages/DataSourceScGuestTestWarns.py
BROKEN=/usr/lib/python3/dist-packages/DataSourceScGuestTestBroken.py

reset_cloud_init() {
    rm -rf /var/lib/cloud /run/cloud-init /var/log/cloud-init.log /var/log/cloud-init-output.log "$WARNS" "$BROKEN"
    printf 'datasource_list: [ %s ]\nnetwork: {config: disabled}\ncloud_init_modules: [ bootcmd ]\n' "$1" > "$SETTINGS"
}

# A boot: cloud-init's local and network stages, then the reporter.
boot() {
    rm -rf /run/cloud-init /run/sc-guest
    cloud-init init --local >/dev/null 2>&1 || true
    cloud-init init >/dev/null 2>&1 || true
    "$SC_GUEST" report || fail "sc-guest report exited $?"
    expect_requests "POST /v1/report/boot"
    echo "   report: $(last_body /v1/report/boot)"
}

has_recoverable_errors() {
    python3 -I -c 'import json, sys; sys.exit(0 if "recoverable_errors" in json.load(open("/run/cloud-init/status.json"))["v1"]["init"] else 1)'
}

expect_error_containing() {
    [[ "$(report_field status)" == '"error"' ]] || fail "report status $(report_field status)"
    report_field errors | grep -qF "$1" || fail "no error containing [$1] in $(report_field errors)"
}

echo "== the datasource loads and a customer's bootcmd fails: done"
reset_cloud_init NoCloud
mkdir -p /var/lib/cloud/seed/nocloud
printf 'instance-id: iid-report-1\nlocal-hostname: report-test\n' > /var/lib/cloud/seed/nocloud/meta-data
printf '#cloud-config\nbootcmd:\n  - [ sh, -c, "exit 3" ]\n' > /var/lib/cloud/seed/nocloud/user-data
boot
grep -q "('bootcmd'," /run/cloud-init/status.json || fail "cloud-init didn't record the bootcmd failure"
[[ "$(report_field status)" == '"done"' ]] || fail "report status $(report_field status)"
[[ "$(report_field errors)" == '[]' ]] || fail "report errors $(report_field errors)"

echo "== reboot: cloud-init restores its cached datasource, and a new report is sent"
boot
grep -q 'restored from cache\|"datasource": "DataSourceNoCloud' /run/cloud-init/status.json || fail "no datasource on reboot"
[[ "$(report_field status)" == '"done"' ]] || fail "report status $(report_field status)"

echo "== the datasource logs a warning, then loads: done"
reset_cloud_init ScGuestTestWarns
cat > "$WARNS" <<'EOF'
import logging

from cloudinit import sources

LOG = logging.getLogger(__name__)


class DataSourceScGuestTestWarns(sources.DataSource):
    dsname = "ScGuestTestWarns"

    def _get_data(self):
        LOG.warning("sc-guest test: retrying")
        self.metadata = {"instance-id": "iid-report-2", "local-hostname": "report-test"}
        self.userdata_raw = b""
        return True


datasources = [(DataSourceScGuestTestWarns, (sources.DEP_FILESYSTEM,))]


def get_datasource_list(depends):
    return sources.list_from_depends(depends, datasources)
EOF
boot
if has_recoverable_errors; then
    # cloud-init 25.1 and later call this boot "degraded done".
    grep -q 'sc-guest test: retrying' /run/cloud-init/status.json || fail "cloud-init didn't record the warning"
fi
[[ "$(report_field status)" == '"done"' ]] || fail "report status $(report_field status)"
[[ "$(report_field errors)" == '[]' ]] || fail "report errors $(report_field errors)"

echo "== the datasource can't be imported: error, with cloud-init's reason"
reset_cloud_init ScGuestTestMissing
boot
expect_error_containing "No instance datasource found."
if has_recoverable_errors; then
    expect_error_containing "Could not import DataSourceScGuestTestMissing"
else
    echo "   this cloud-init records no reason beyond that"
fi

echo "== the datasource loads but fails: error, with cloud-init's reason"
reset_cloud_init ScGuestTestBroken
cat > "$BROKEN" <<'EOF'
from cloudinit import sources


class DataSourceScGuestTestBroken(sources.DataSource):
    dsname = "ScGuestTestBroken"

    def _get_data(self):
        raise RuntimeError("test failure")


datasources = [(DataSourceScGuestTestBroken, (sources.DEP_FILESYSTEM,))]


def get_datasource_list(depends):
    return sources.list_from_depends(depends, datasources)
EOF
boot
expect_error_containing "No instance datasource found."
if has_recoverable_errors; then
    expect_error_containing "Getting data from <class 'DataSourceScGuestTestBroken.DataSourceScGuestTestBroken'> failed"
else
    echo "   this cloud-init records no reason beyond that"
fi
rm -f "$WARNS" "$BROKEN" "$SETTINGS"

echo "report: ok"
