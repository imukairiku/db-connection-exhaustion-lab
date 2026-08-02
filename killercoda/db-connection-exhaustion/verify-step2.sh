#!/usr/bin/env bash
# =============================================================================
# Step2 検証(復旧済み状態も合格扱い)
# =============================================================================
set -Eeuo pipefail

fail() { echo "[VERIFY NG] $*" >&2; exit 1; }

psql_q() {
  docker exec -i db-server psql -U postgres -d appdb -Atq -c "$1" 2>/dev/null
}

docker inspect db-server >/dev/null 2>&1 || fail "db-server が見つかりません"

total="$(psql_q "SELECT count(*) FROM pg_stat_activity
                 WHERE backend_type='client backend';")" \
  || fail "DBへ接続できません(db-serverの状態を確認してください)"

leftover="$(psql_q "SELECT count(*) FROM pg_stat_activity
                    WHERE backend_type='client backend'
                      AND application_name='ap-server-1';")"

if [ "${total}" -ge 15 ] && [ "${leftover}" -ge 1 ]; then
  echo "[VERIFY OK] Step2: 接続枯渇状態(合計${total}本、ap-server-1残留${leftover}本)を確認しました"
  exit 0
fi

if [ "${leftover}" -eq 0 ]; then
  ok="$(psql_q "SELECT count(*) FROM job_history
                WHERE ap_name='ap-server-2'
                  AND status='success'
                  AND finished_at > now() - interval '5 minutes';")"
  if [ "${ok:-0}" -gt 0 ]; then
    echo "[VERIFY OK] Step2: 既に復旧済みの状態を確認しました(Step3実施済み)。そのまま進んでください"
    exit 0
  fi
fi

fail "接続枯渇状態を確認できません(合計${total}本、ap-server-1残留${leftover}本)。状態が崩れた場合は /root/lab/scripts/create-failed-state.sh で再構築できます"
