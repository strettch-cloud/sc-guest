#!/bin/bash
# Posts this run's job results and coverage reports on the pull request, as
# one comment that later runs update instead of adding another.
# Usage: pr-comment.sh <directory with one coverage.txt per system, at any depth>
# Needs GH_TOKEN, GH_REPO, PR, HEAD_SHA, RUN_ID and RUN_ATTEMPT.
set -euo pipefail

REPORTS="${1:?usage: pr-comment.sh <coverage directory>}"
MARKER="<!-- sc-guest-ci-results -->"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/$GH_REPO/actions/runs/$RUN_ID"
BODY="$(mktemp)"

{
  echo "$MARKER"
  echo "### CI results for ${HEAD_SHA:0:7}"
  echo
  echo "| Job | Result |"
  echo "|---|---|"
  # This job and the ones still running are left out.
  gh api --paginate "repos/$GH_REPO/actions/runs/$RUN_ID/attempts/$RUN_ATTEMPT/jobs" \
    --jq '.jobs[] | select(.status == "completed") | "| \(.name) | \(.conclusion) |"'
  echo
  echo "#### Coverage"
  found=false
  while IFS= read -r report; do
    found=true
    echo
    echo '```'
    cat "$report"
    echo '```'
  done < <(find "$REPORTS" -name coverage.txt -type f 2>/dev/null | sort)
  "$found" || { echo; echo "No coverage reports: the tests didn't run."; }
  echo
  echo "[Run $RUN_ID]($RUN_URL)"
} > "$BODY"

IDS="$(gh api --paginate "repos/$GH_REPO/issues/$PR/comments" \
  --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | startswith(\"$MARKER\"))) | .id")"
ID="${IDS%%$'\n'*}"
if [ -n "$ID" ]; then
  gh api --method PATCH "repos/$GH_REPO/issues/comments/$ID" -F "body=@$BODY" > /dev/null
else
  gh api "repos/$GH_REPO/issues/$PR/comments" -F "body=@$BODY" > /dev/null
fi
