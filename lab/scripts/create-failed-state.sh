#!/usr/bin/env bash
# =============================================================================
# 演習開始状態の自動構築
# =============================================================================
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SCRIPTS_DIR="${COMMON_SH_DIR}"
NEED_LEFTOVER=8
MAX_ATTEMPTS=3

log_info "=== 演習開始状態(障害発生済み)の構築を開始します ==="

"${SCRIPTS_DIR}/setup.sh"

attempt=1
while [ "${attempt}" -le "${MAX_ATTEMPTS}" ]; do
  log_info "--- 障害投入 試行 ${attempt}/${MAX_ATTEMPTS} ---"

  "${SCRIPTS_DIR}/start-normal-load.sh"

  wait_for_conns_at_least "${AP1_CONTAINER}" "${NEED_LEFTOVER}" 90

  "${SCRIPTS_DIR}/inject-failure.sh"

  wait_for_log_pattern "${AP2_CONTAINER}" "PROMOTED to ACTIVE" 40

  sleep 5
  leftover="$(count_conns "${AP1_CONTAINER}")"
  log_info "ap-server-1 由来の残留接続: ${leftover} 本"
  if [ "${leftover}" -ge "${NEED_LEFTOVER}" ]; then
    break
  fi
  log_warn "残留接続が ${NEED_LEFTOVER} 本未満のためリトライします"
  attempt=$((attempt + 1))
  if [ "${attempt}" -gt "${MAX_ATTEMPTS}" ]; then
    log_error "障害状態の構築に失敗しました(残留接続不足)"
    exit 1
  fi
done

wait_for_log_pattern "${AP2_CONTAINER}" "DB connection failed" 60

log_info "=== 演習開始状態の構築完了 ==="
log_info "  ap-server-1 : $(container_state "${AP1_CONTAINER}")(通信断+pause)"
log_info "  ap-server-2 : $(container_state "${AP2_CONTAINER}")(昇格済み・接続エラー発生中)"
log_info "  残留接続    : $(count_conns "${AP1_CONTAINER}") 本"
log_info "  総接続数    : $(count_client_conns) 本(max_connections=20)"
