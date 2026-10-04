#!/bin/bash
# Called by the reviewed SSM deployment workflow or the boot preparation service.
set -euo pipefail
exec 9>/run/packetloss-maintenance.lock
flock -n 9 || { echo 'Another maintenance operation is running.' >&2; exit 1; }
archive_path=${1:?archive path required}
release=${2:?release SHA required}
digest=${3:?archive SHA256 required}
mode=${4:-}
set -a
source /etc/packetloss/server.env
set +a
: "${GAME_ADMIN_TOKEN:?admin token required}"
[[ "$release" =~ ^[0-9a-f]{40}$ ]] && [[ "$digest" =~ ^[0-9a-f]{64}$ ]]
[[ "$mode" == '' || "$mode" == '--force' || "$mode" == '--boot' ]]
admin_curl=(--fail --silent --show-error --connect-timeout 2 --max-time 5 -H "Authorization: Bearer $GAME_ADMIN_TOKEN")
monotonic_seconds() {
  awk '{ print int($1) }' /proc/uptime
}
printf '%s  %s\n' "$digest" "$archive_path" | sha256sum -c -
release_dir="/opt/packetloss/releases/$release"
previous=$(readlink -f /opt/packetloss/current || true)
# Reject traversal, absolute paths, links and device entries before extraction.
/usr/local/bin/packetloss-node /usr/local/lib/packetloss/validate-archive.mjs "$archive_path"
if [[ -d "$release_dir" ]]; then
  [[ "$(cat "$release_dir/artifact.sha256")" == "$digest" ]]
else
  staging=$(mktemp -d /opt/packetloss/releases/.staging.XXXXXXXX)
  trap 'rm -rf "$staging"' EXIT
  tar -xzf "$archive_path" -C "$staging" --no-same-owner
  test -s "$staging/server.js"
  test -s "$staging/manifest.json"
  printf '%s\n' "$digest" >"$staging/artifact.sha256"
  chown -R root:root "$staging"
  chmod -R a+rX "$staging"
  mv "$staging" "$release_dir"
  trap - EXIT
fi
if [[ "$mode" != '--boot' ]] && systemctl is-active --quiet packetloss; then
  curl "${admin_curl[@]}" -X POST http://127.0.0.1:8081/internal/drain >/dev/null
  if [[ "$mode" == '--force' ]]; then
    curl "${admin_curl[@]}" -X POST http://127.0.0.1:8081/internal/abort >/dev/null
  else
    drained=false
    drain_deadline=$(( $(monotonic_seconds) + 420 ))
    while (( $(monotonic_seconds) < drain_deadline )); do
      if ! state=$(curl "${admin_curl[@]}" http://127.0.0.1:8081/internal/status); then sleep 5; continue; fi
      if jq -e '.activeMatches == 0 and .pendingResults == 0' <<<"$state" >/dev/null; then drained=true; break; fi
      sleep 5
    done
    if [[ "$drained" != true ]]; then
      curl "${admin_curl[@]}" -X POST http://127.0.0.1:8081/internal/resume >/dev/null || true
      echo 'Drain timed out; keeping the running release.' >&2
      exit 1
    fi
  fi
fi
ln -sfn "$release_dir" /opt/packetloss/next
mv -Tf /opt/packetloss/next /opt/packetloss/current
if [[ "$mode" == '--boot' ]]; then exit 0; fi
resume_and_check() {
  local deadline resumed
  deadline=$(( $(monotonic_seconds) + 90 ))
  resumed=false
  while (( $(monotonic_seconds) < deadline )); do
    if curl "${admin_curl[@]}" \
      -X POST http://127.0.0.1:8081/internal/resume >/dev/null 2>&1; then
      resumed=true
      break
    fi
    sleep 2
  done
  [[ "$resumed" == true ]] || return 1
  while (( $(monotonic_seconds) < deadline )); do
    if curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
      http://127.0.0.1:8080/ready >/dev/null; then return 0; fi
    sleep 2
  done
  return 1
}
if timeout 60 systemctl restart packetloss && resume_and_check; then
  if [[ -n "$previous" && "$previous" != "$release_dir" ]]; then ln -sfn "$previous" /opt/packetloss/previous; fi
  exit 0
fi
if [[ -n "$previous" && -d "$previous" ]]; then
  ln -sfn "$previous" /opt/packetloss/next
  mv -Tf /opt/packetloss/next /opt/packetloss/current
  if timeout 60 systemctl restart packetloss && resume_and_check; then
    echo 'Deployment failed; previous release readiness confirmed.' >&2
    exit 1
  fi
fi
echo 'Deployment failed and rollback readiness is unverified; operator intervention required.' >&2
exit 1
