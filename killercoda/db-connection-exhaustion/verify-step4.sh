#!/usr/bin/env bash
# =============================================================================
# Step4 検証
# =============================================================================
set -Eeuo pipefail

fail() { echo "[VERIFY NG] $*" >&2; exit 1; }

psql_q() {
  docker exec -i db-server psql -U postgres -d appdb -Atq -c "$1" 2>/dev/null
}

RETEST_MARKER="/tmp/lab-state/retest-done"

timeout_val="$(psql_q 'SHOW idle_in_transaction_session_timeout;')" || fail "DBへ接続できません"

[ "${timeout_val}" = "30s" ] \
  || fail "idle_in_transaction_session_timeout が適用されていません (現在値: ${timeout_val})。/root/lab/scripts/apply-keepalive-setting.sh を実行してください"

[ -f "${RETEST_MARKER}" ] \
  || fail "再試験が完了していません。/root/lab/scripts/retest.sh を実行してください"

leftover="$(psql_q "SELECT count(*) FROM pg_stat_activity
                    WHERE backend_type='client backend'
                      AND application_name='ap-server-1';")"
[ "${leftover}" -eq 0 ] \
  || fail "ap-server-1 由来の接続が ${leftover} 本残っています(再試験の完了を待ってください)"

ok="$(psql_q "SELECT count(*) FROM job_history
              WHERE ap_name='ap-server-2'
                AND status='success'
                AND finished_at > now() - interval '3 minutes';")"
if [ "${ok}" -eq 0 ]; then
  docker logs --since 3m ap-server-2 2>&1 | grep -q "job SUCCESS" \
    || fail "ap-server-2 の業務成功を確認できません"
fi

echo "[VERIFY OK] Step4: 恒久対策と再試験の完了を確認しました。finish へ進んでください"
exit 0