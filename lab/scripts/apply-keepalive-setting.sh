#!/usr/bin/env bash
# =============================================================================
# 恒久対策: idle_in_transaction_session_timeout の適用
#
#   idle_in_transaction_session_timeout = 30s
#     → トランザクション中に30秒何もない接続を強制切断する
#
# 【なぜKeepaliveではなくこの設定か】
#   今回の残留接続は 'idle in transaction' 状態(Step2で観察)。
#   TCP Keepaliveは「サイレントに切れたTCP接続」を検知する仕組みだが、
#   環境によっては setsockopt(TCP_KEEPIDLE) がサポートされない場合がある。
#   一方 idle_in_transaction_session_timeout はPostgreSQL内部のタイマーで
#   動作するため、環境非依存で確実にidle-in-transaction接続を回収できる。
#
# 【重要】この値(30秒)は演習で効果を短時間に観察するための値です。
#   本番環境では、業務トランザクションの最長実行時間を踏まえて
#   十分に長い値を設計してください(そのまま流用しないこと)。
# =============================================================================
set -Eeuo pipefail
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/common.sh"

log_info "=== idle_in_transaction_session_timeout を適用します ==="

psql_admin "ALTER SYSTEM SET idle_in_transaction_session_timeout = '30s';" >/dev/null
psql_admin "SELECT pg_reload_conf();"                                       >/dev/null

sleep 2

echo ""
echo "---- 適用後の設定値 ----"
printf '%-42s = %s\n' "idle_in_transaction_session_timeout" \
  "$(psql_admin "SHOW idle_in_transaction_session_timeout;")"
echo ""

log_info "設定を適用しました(検知目安: 約30秒)"
log_warn "既存の接続にも動的に適用されます"
log_warn "この値は演習専用です。本番環境ではそのまま使用しないでください"