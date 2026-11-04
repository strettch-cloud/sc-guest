#!/bin/bash
# Prints the Debian version for a release tag. A pre-release such as
# 1.2.0-beta.3 becomes 1.2.0~beta.3: apt sorts "~" below everything, so a
# beta is older than its stable release. With "-" it would be newer.
set -euo pipefail

TAG="${1:?usage: deb-version.sh <tag>}"

if ! [[ "$TAG" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-([0-9A-Za-z.]+))?$ ]]; then
    echo "not a release tag: $TAG" >&2
    exit 1
fi

if [[ -n "${BASH_REMATCH[3]}" ]]; then
    echo "${BASH_REMATCH[1]}~${BASH_REMATCH[3]}"
else
    echo "$TAG"
fi
