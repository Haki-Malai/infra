#!/bin/bash
# The IAM-authorized control Lambda invokes this fixed helper through SSM.
set -euo pipefail
mode=${1:-}
[[ "$mode" == '' || "$mode" == '--force' ]]
exec 9>/run/packetloss-maintenance.lock
flock -n 9 || { echo 'Maintenance in progress; stop refused.' >&2; exit 1; }
source /etc/packetloss/server.env
: "${GAME_ADMIN_TOKEN:?admin token missing}"
admin() {
  printf 'header = "Authorization: Bearer %s"\n' "$GAME_ADMIN_TOKEN" | \
    curl --config - --fail --silent --show-error --max-time 5 -X "$2" "http://127.0.0.1:8081/internal/$1"
}
admin drain POST >/dev/null
if [[ "$mode" == '--force' ]]; then admin abort POST >/dev/null; fi
status=$(admin status GET)
if [[ "$mode" == '--force' ]]; then
  for ((attempt=0; attempt<5; attempt++)); do
    if jq -e '.pendingResults == 0' <<<"$status" >/dev/null; then break; fi
    sleep 1
    status=$(admin status GET)
  done
fi
jq --argjson force "$([[ "$mode" == '--force' ]] && echo true || echo false)" \
  '{safeToStop:($force or (.activeMatches == 0 and .pendingResults == 0)),activeMatches,pendingResults}' <<<"$status"
