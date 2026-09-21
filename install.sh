#!/usr/bin/env bash
#
# Install the observability shipper on this host.
#
#   curl -fsSL https://raw.githubusercontent.com/OWNER/observability-shipper/main/install.sh \
#     | sudo bash -s -- <project-name>
#
# Idempotent: re-running updates the three tracked files and leaves .env
# alone. Nothing is started -- review .env, then `docker compose up -d`.

set -euo pipefail

REPO="${SHIPPER_REPO:-https://raw.githubusercontent.com/OWNER/observability-shipper/main}"
DEST="${SHIPPER_DEST:-/opt/observability}"
PROJECT="${1:-}"

if [[ $EUID -ne 0 ]]; then
  echo "run with sudo" >&2
  exit 1
fi

command -v curl >/dev/null || { echo "curl not found" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose not found" >&2; exit 1; }

mkdir -p "$DEST"

for f in compose.yaml config.alloy .env.template; do
  echo "fetch: $f"
  curl -fsSL "$REPO/$f" -o "$DEST/$f"
done

if [[ -f "$DEST/.env" ]]; then
  echo "keep:  .env (already present, not overwritten)"
else
  cp "$DEST/.env.template" "$DEST/.env"
  chmod 600 "$DEST/.env"
  if [[ -n "$PROJECT" ]]; then
    sed -i \
      -e "s/^PROJECT_NAME=.*/PROJECT_NAME=$PROJECT/" \
      -e "s/^CONTAINER_PREFIX=.*/CONTAINER_PREFIX=$PROJECT/" \
      -e "s/^PROJECT_HOSTNAME=.*/PROJECT_HOSTNAME=$PROJECT/" \
      "$DEST/.env"
    echo "wrote: .env with PROJECT_NAME=$PROJECT"
  else
    echo "wrote: .env from template (no project name given)"
  fi
fi

cat <<NEXT

Installed to $DEST

Next:
  1. $EDITOR $DEST/.env
     Set LOKI_ENDPOINT and METRICS_ENDPOINT. They are deliberately blank --
     a wrong value ships this host's logs to the wrong aggregator, and that
     failure is silent.
  2. cd $DEST && docker compose up -d
  3. Confirm in Grafana:  {project="${PROJECT:-<project>}"}

NEXT
