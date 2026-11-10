#!/bin/bash
# Points an Ubuntu container's apt at Azure's Ubuntu mirror, falling back to
# Canonical's servers. Does nothing on other systems.
#
# GitHub's hosted runners are Azure VMs and set up their own apt this way, but
# a container started on one still uses archive.ubuntu.com and
# security.ubuntu.com, which can be slow or inconsistent from Azure while
# Azure's mirror is not. Plain http: the images have no CA certificates.
set -euo pipefail

# shellcheck source=/dev/null
. /etc/os-release
[ "$ID" = ubuntu ] || exit 0

list=/etc/apt/apt-mirrors.txt
printf '%s\tpriority:%s\n' \
    http://azure.archive.ubuntu.com/ubuntu/ 1 \
    http://archive.ubuntu.com/ubuntu/ 2 \
    http://security.ubuntu.com/ubuntu/ 3 > "$list"

# 22.04 lists its sources in sources.list, 24.04 in ubuntu.sources.
for sources in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
    [ -f "$sources" ] || continue
    sed -i -E "s#http://(archive|security)\.ubuntu\.com/ubuntu/?#mirror+file:$list#" "$sources"
done

# apt retries a failed download on the same mirror before it moves to the next
# one, and its defaults (3 retries, 30 s without data) would hold every file on
# a stalled mirror for minutes. These are the values GitHub's runners use. A
# mirror that is slow but still sending data never times out; the workflow's
# step and job timeouts bound that.
cat > /etc/apt/apt.conf.d/zz-mirror-failover <<'EOF'
Acquire::Retries "1";
Acquire::http::Timeout "15";
EOF
