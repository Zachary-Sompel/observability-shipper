#!/usr/bin/env bash
#
# Make Alloy read the backfill directory again.
#
#   ./reingest-backfill.sh --dry-run
#   ./reingest-backfill.sh
#
# Why this is not just "restart it". Alloy records how far it has read into
# every file, keyed by path, and honours that across restarts -- which is
# exactly what you want for live logs and exactly what stops a backfill being
# re-read. Deleting the whole positions store would work and would also make
# Alloy re-read every live nginx log from the beginning, duplicating days of
# traffic across the fleet.
#
# So this removes the state for loki.source.file.nginx_backfill only, with
# Alloy stopped, and leaves every other component's position untouched.
#
# Delete the old unlabelled copy from Loki first, on the aggregator:
#   ./scripts/delete-backfill.sh
# Order is not critical -- the delete targets {backfill="true", bot=""} and
# re-ingested lines carry a bot label -- but doing it first avoids a window
# where the same requests are counted twice.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

dry_run=0
[[ "${1:-}" == "--dry-run" ]] && dry_run=1
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { sed -n '2,25p' "$0"; exit 0; }

backfill_dir="$(grep -E '^NGINX_BACKFILL_DIR=' .env 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' ' || true)"
if [[ -z "$backfill_dir" ]]; then
  echo "NGINX_BACKFILL_DIR is not set in .env -- nothing to re-ingest." >&2
  echo "Set it, and LOG_MAX_AGE, then run this." >&2
  exit 1
fi
if ! compgen -G "$backfill_dir/*.log" > /dev/null; then
  echo "no *.log files in $backfill_dir -- rebuild them before re-ingesting." >&2
  exit 1
fi
echo "backfill files:"
ls -l "$backfill_dir"/*.log | sed 's/^/  /'

volume="$(docker inspect -f \
  '{{range .Mounts}}{{if eq .Destination "/var/lib/alloy/data"}}{{.Name}}{{end}}{{end}}' \
  system-alloy 2>/dev/null || true)"
[[ -n "$volume" ]] || { echo "could not find system-alloy's data volume" >&2; exit 1; }
mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "$volume")"

mapfile -t state < <(find "$mountpoint" -maxdepth 2 -name '*nginx_backfill*' 2>/dev/null || true)
if [[ ${#state[@]} -eq 0 ]]; then
  echo
  echo "no stored position for loki.source.file.nginx_backfill."
  echo "Either it has never read anything -- in which case a plain"
  echo "'docker compose up -d' is all you need -- or Alloy names its state"
  echo "differently in this version. Check under: $mountpoint"
  exit 0
fi
echo
echo "position state to remove (volume $volume):"
printf '  %s\n' "${state[@]}"

if [[ "$dry_run" == 1 ]]; then
  echo
  echo "dry run -- nothing stopped, nothing removed"
  exit 0
fi

read -rp "stop alloy, clear that state, and re-read the backfill? [y/N] " reply
[[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "aborted"; exit 0; }

docker compose stop alloy
rm -rf "${state[@]}"
docker compose start alloy

cat <<'NOTE'

Alloy is reading the backfill again, this time classifying each line.

  docker compose logs -f alloy
  # then, on the aggregator:
  curl -s "http://<loki>:3100/loki/api/v1/label/bot/values"

Unset NGINX_BACKFILL_DIR and LOG_MAX_AGE and run 'docker compose up -d' once
it has drained, or the next restart re-reads it all again.
NOTE
