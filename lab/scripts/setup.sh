#!/usr/bin/env bash
# =============================================================================
# 演習環境セットアップ
# =============================================================================
set -Eeuo pipefail
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/common.sh"

log_info "=== 演習環境セットアップ開始 ==="

log_info "イメージをビルドしています(初回は数分かかります)..."
compose build

log_info "コンテナを起動しています..."
compose up -d

wait_for_db_healthy 120

for c in "${AP1_CONTAINER}" "${AP2_CONTAINER}"; do
  if [ "$(container_state "${c}")" != "running" ]; then
    log_error "${c} が起動していません(state=$(container_state "${c}"))"
    docker logs --tail 20 "${c}" || true
    exit 1
  fi
done

log_info "ap-server-1 の業務処理開始を待機中..."
wait_for_conns_at_least "${AP1_CONTAINER}" 5 60

log_info "=== セットアップ完了 ==="
compose ps
