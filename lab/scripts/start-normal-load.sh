#!/usr/bin/env bash
# =============================================================================
# 通常負荷の開始(冪等)
# =============================================================================
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

log_info "=== 通常負荷を開始します ==="

if [ "$(container_state "${AP1_CONTAINER}")" = "paused" ]; then
  log_info "ap-server-1 がpause状態のためunpauseします"
  docker unpause "${AP1_CONTAINER}"
fi
clear_drop

log_info "DB側の古い業務接続を掃除します..."
psql_admin "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
            WHERE backend_type='client backend'
              AND application_name IN ('${AP1_CONTAINER}','${AP2_CONTAINER}')
              AND pid <> pg_backend_pid();" >/dev/null || true

log_info "APコンテナを再起動して役割を初期化します..."
docker restart "${AP1_CONTAINER}" >/dev/null
docker restart "${AP2_CONTAINER}" >/dev/null

wait_for_conns_at_least "${AP1_CONTAINER}" 8 90

log_info "=== 通常負荷が稼働中です ==="
"${COMMON_SH_DIR}/show-connections.sh"
