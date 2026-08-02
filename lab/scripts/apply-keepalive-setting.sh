#!/usr/bin/env bash
# =============================================================================
# 恒久対策: TCP Keepalive設定の適用
# =============================================================================
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

log_info "=== TCP Keepalive設定を適用します ==="

psql_admin "ALTER SYSTEM SET tcp_keepalives_idle = 20;"     >/dev/null
psql_admin "ALTER SYSTEM SET tcp_keepalives_interval = 5;"  >/dev/null
psql_admin "ALTER SYSTEM SET tcp_keepalives_count = 3;"     >/dev/null
psql_admin "SELECT pg_reload_conf();"                        >/dev/null

sleep 2

echo ""
echo "---- 適用後の設定値 ----"
for p in tcp_keepalives_idle tcp_keepalives_interval tcp_keepalives_count; do
  printf '%-28s = %s\n' "${p}" "$(psql_admin "SHOW ${p};")"
done
echo ""

log_info "設定を適用しました(検知目安: 20 + 5×3 = 約35秒)"
log_warn "既存の接続には適用されません。新規接続から有効になります"
log_warn "この値は演習専用です。本番環境ではそのまま使用しないでください"
