#!/usr/bin/env bash
# =============================================================================
# 環境の正常化(冪等)
# =============================================================================
set -Eeuo pipefail
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/common.sh"

SCRIPTS_DIR="${COMMON_SH_DIR}"

log_info "=== 環境を正常状態へ戻します ==="

"${SCRIPTS_DIR}/clear-failure.sh"

if [ "$(container_state "${DB_CONTAINER}")" != "running" ]; then
  log_info "db-server を起動します..."
  compose up -d
  wait_for_db_healthy 120
fi

"${SCRIPTS_DIR}/start-normal-load.sh"

log_info "=== 環境の正常化が完了しました ==="
