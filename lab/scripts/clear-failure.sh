#!/usr/bin/env bash
# =============================================================================
# 障害解除(冪等)
# =============================================================================
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

log_info "=== 障害解除を開始します ==="

if [ "$(container_state "${AP1_CONTAINER}")" = "paused" ]; then
  log_info "ap-server-1 をunpauseします"
  docker unpause "${AP1_CONTAINER}"
fi

clear_drop

log_info "=== 障害解除完了 ==="
