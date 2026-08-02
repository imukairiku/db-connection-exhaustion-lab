#!/usr/bin/env bash
# =============================================================================
# Step1 検証
# =============================================================================
set -Eeuo pipefail

state_of() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "notfound"
}

fail() { echo "[VERIFY NG] $*" >&2; exit 1; }

[ "$(state_of ap-server-1)" = "paused" ] \
  || fail "ap-server-1 が paused ではありません (state=$(state_of ap-server-1))"

[ "$(state_of ap-server-2)" = "running" ] \
  || fail "ap-server-2 が running ではありません (state=$(state_of ap-server-2))"

[ "$(state_of db-server)" = "running" ] \
  || fail "db-server が running ではありません (state=$(state_of db-server))"

echo "[VERIFY OK] Step1: 障害状態(ap1=paused, ap2=running, db=running)を確認しました"
exit 0
