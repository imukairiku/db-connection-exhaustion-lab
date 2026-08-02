#!/usr/bin/env bash
# =============================================================================
# DB接続状況の表示
# =============================================================================
set -Eeuo pipefail
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/common.sh"

echo "=========================================="
echo " DB接続状況 (max_connections=$(psql_admin 'SHOW max_connections;'))"
echo "=========================================="
docker exec -i "${DB_CONTAINER}" psql -U postgres -d appdb -c "
SELECT
    application_name,
    client_addr,
    state,
    count(*)
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY application_name, client_addr, state
ORDER BY application_name;"

echo "クライアント接続合計: $(count_client_conns) 本"
echo "(注: pg_stat_activity全体にはバックグラウンドプロセスも含まれます)"
