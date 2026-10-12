#!/usr/bin/env bash
set -Eeuo pipefail
REPO_URL="https://github.com/imukairiku/ap-db-connection-exhaustion-lab.git"
SOURCE_COMMIT="0bdb03aa7390089044bda01c84ba740c3565b31d"
REPO_DIR="/root/ap-db-connection-exhaustion-lab"
READY="/opt/ap-db-scenario-ready"
FAILED="/opt/ap-db-scenario-failed"
LOG="/var/log/ap-db-scenario-setup.log"

trap 'touch "$FAILED"' ERR
setup_scenario() {
  rm -f "$READY" "$FAILED"
  for attempt in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done
  docker info >/dev/null
  if [ ! -e "$REPO_DIR" ]; then
    git clone --no-checkout "$REPO_URL" "$REPO_DIR"
  else
    [ -d "$REPO_DIR/.git" ]
    [ "$(git -C "$REPO_DIR" remote get-url origin)" = "$REPO_URL" ]
    [ -z "$(git -C "$REPO_DIR" status --porcelain)" ]
  fi
  git -C "$REPO_DIR" fetch origin "$SOURCE_COMMIT"
  git -C "$REPO_DIR" checkout --detach "$SOURCE_COMMIT"
  cd "$REPO_DIR"
  bash scripts/scenario-reset.sh
  bash scripts/scenario-inject.sh
  touch "$READY"
}
setup_scenario >"$LOG" 2>&1
