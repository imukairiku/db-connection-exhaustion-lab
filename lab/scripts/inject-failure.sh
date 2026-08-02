#!/usr/bin/env bash
# =============================================================================
# 障害投入
# =============================================================================
set -Eeuo pipefail
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/common.sh"

log_info "=== 障害投入を開始します ==="

state="$(container_state "${AP1_CONTAINER}")"
if [ "${state}" = "paused" ]; then
  log_warn "ap-server-1 は既にpause状態です(障害投入済み)"
  exit 0
fi
if [ "${state}" != "running" ]; then
  log_error "ap-server-1 がrunningではありません(state=${state})。setup.shを実行してください"
  exit 1
fi

apply_drop

log_info "DROP安定待ち(3秒)..."
sleep 3

log_info "ap-server-1 を pause します..."
docker pause "${AP1_CONTAINER}"

log_info "=== 障害投入完了 ==="
log_info "採用したDROP方式: $(cat "${DROP_METHOD_FILE}" 2>/dev/null || echo unknown)"
log_info "約10秒後に ap-server-2 が自動昇格します"
