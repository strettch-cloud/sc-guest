#!/bin/bash
# Posts each system's test coverage on the pull request, as one comment that
# later runs update instead of adding another. The heading and layout match
# the coverage comments of Strettch Cloud's other repositories. The heading
# also identifies the comment: changing it makes the next run post a new one.
# Usage: coverage-comment.sh <directory with one coverage.txt per system, at any depth>
# Needs GH_TOKEN, GH_REPO and PR.
set -euo pipefail

REPORTS="${1:?usage: coverage-comment.sh <coverage directory>}"
HEADING="📊 Test Coverage Report"
BODY="$(mktemp)"

mapfile -t reports < <(find "$REPORTS" -name coverage.txt -type f 2>/dev/null | sort)
{
  echo "## $HEADING"
  echo
  if [ "${#reports[@]}" -eq 0 ]; then
    echo "*No coverage data: the tests didn't run.*"
  else
    echo "| System | Coverage | Status |"
    echo "|--------|----------|--------|"
    for report in "${reports[@]}"; do
      # The layout is described in tests/datasource.sh. read leaves a variable
      # empty for a missing line.
      { read -r system; read -r minimum; read -r total; read -r status; } < "$report" || true
      if [ -z "$total" ]; then
        echo "| $system | ⚠️ no coverage data | ❌ |"
      elif [ "$status" = 0 ]; then
        echo "| $system | $total | ✅ |"
      else
        echo "| $system | $total | ❌ below $minimum% |"
      fi
    done
    echo
    echo "*Each system ran the tests against its own cloud-init. Minimum coverage is $minimum%.*"
  fi
} > "$BODY"

IDS="$(gh api --paginate "repos/$GH_REPO/issues/$PR/comments" \
  --jq ".[] | select(.user.type == \"Bot\" and (.body | contains(\"$HEADING\"))) | .id")"
ID="${IDS%%$'\n'*}"
if [ -n "$ID" ]; then
  gh api --method PATCH "repos/$GH_REPO/issues/comments/$ID" -F "body=@$BODY" > /dev/null
else
  gh api "repos/$GH_REPO/issues/$PR/comments" -F "body=@$BODY" > /dev/null
fi
