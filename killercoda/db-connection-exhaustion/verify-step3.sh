#!/usr/bin/env bash
# =============================================================================
# Step3 検証
# =============================================================================
set -Eeuo pipefail

fail() { echo "[VERIFY NG] $*" >&2; exit 1; }

psql_q() {
  docker exec -i db-server psql -U postgres -d appdb -Atq -c "$1" 2>/dev/null
}

leftover="$(psql_q "SELECT count(*) FROM pg_stat_activity
                    WHERE backend_type='client backend'
                      AND application_name='ap-server-1';")" \
  || fail "DBへ接続できません(db-serverの状態を確認してください)"

[ "${leftover}" -eq 0 ] \
  || fail "ap-server-1 由来の接続がまだ ${leftover} 本残っています。問4の pg_terminate_backend を実施してください"

ok="$(psql_q "SELECT count(*) FROM job_history
              WHERE ap_name='ap-server-2'
                AND status='success'
                AND finished_at > now() - interval '2 minutes';")"

if [ "${ok}" -eq 0 ]; then
  docker logs --since 2m ap-server-2 2>&1 | grep -q "job SUCCESS" \
    || fail "ap-server-2 の業務成功を確認できません。接続終了後、数秒〜10秒待ってから再度CHECKしてください"
fi

echo "[VERIFY OK] Step3: 暫定復旧(残留0本、ap-server-2業務回復)を確認しました"
exit 0
