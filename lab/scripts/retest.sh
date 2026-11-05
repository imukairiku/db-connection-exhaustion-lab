#!/usr/bin/env bash
# =============================================================================
# 再試験(問7)
#   idle_in_transaction_session_timeout 対策後に同一障害を再現し、
#   残留接続が自動解放されて ap-server-2 の業務処理が回復することを
#   時系列で確認する
# =============================================================================
set -Eeuo pipefail
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/common.sh"

SCRIPTS_DIR="${COMMON_SH_DIR}"
RELEASE_TIMEOUT=120
INTERVAL=10

# Display helpers are local to this script; shared operation semantics stay intact.
log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
log_ok() { printf '[OK] %s\n' "$*"; }
phase() {
  printf '\n========================================================\n'
  log_info "$*"
}
current_phase="事前確認"
trap 'rc=$?; if [ "$rc" -ne 0 ]; then log_error "最終判定: 再試験失敗 (工程: ${current_phase}, exit=${rc})"; fi' EXIT

log_info "=== 再試験を開始します ==="

# 1. 恒久対策の事前チェック
timeout_val="$(psql_admin 'SHOW idle_in_transaction_session_timeout;')"
if [ "${timeout_val}" != "30s" ]; then
  log_error "idle_in_transaction_session_timeout が未適用です (現在値: ${timeout_val})"
  log_error "先に ./apply-keepalive-setting.sh を実行してください"
  exit 1
fi
log_ok "設定確認: idle_in_transaction_session_timeout = ${timeout_val} (効果は再試験で確認します)"

rm -f "${RETEST_MARKER}"

current_phase="Phase 1: 正常状態への復旧"
phase "${current_phase} — 障害状態を解除し、通常負荷を開始します"
"${SCRIPTS_DIR}/reset-environment.sh"
log_ok "正常化処理が完了しました。通常負荷の開始を子スクリプトが確認しました"
log_info "コンテナ実測状態: AP1=$(container_state "${AP1_CONTAINER}") AP2=$(container_state "${AP2_CONTAINER}")"
log_info "コンテナの稼働状態だけではAPの役割や業務成功は判断できません"

current_phase="Phase 2: 障害投入"
phase "${current_phase} — AP1とDB間の通信を遮断し、AP1を一時停止します"
fault_started_at=${SECONDS}
"${SCRIPTS_DIR}/inject-failure.sh"
log_ok "障害投入処理が完了しました。AP1実測状態=$(container_state "${AP1_CONTAINER}")"
log_info "通信遮断の後に一時停止するため、DB側の接続終了検知とは別の出来事です"

current_phase="Phase 3: AP2への自動切替"
phase "${current_phase} — 現在のAP2プロセスがACTIVEになるまで待ちます"
wait_for_ap_active "${AP2_CONTAINER}" 40
log_ok "AP2=ACTIVE (現在プロセスの役割情報を確認)。手動昇格は行っていません"
log_info "自動切替の確認であり、業務回復の判定はPhase 5で行います"

current_phase="Phase 4: DB接続数・状態の観測"
phase "${current_phase} — AP1残留接続とAP2接続数の推移を観測します"
log_info "障害経過=障害投入スクリプト呼出し直前から、観測経過=この工程の開始からの実経過秒"
log_info "どちらもDBセッションの無操作時間ではありません。30sはトランザクション中の要求待ち時間です"
log_info "観測開始の30秒後に必ず切断されるわけではありません。接続本数・解放時間は変動します"
observation_started_at=${SECONDS}
printf '%-12s %-12s %-18s %-18s\n' '障害経過(秒)' '観測経過(秒)' 'ap-server-1(本)' 'ap-server-2(本)'
elapsed=0
released=1
observed_residual=0
while [ "${elapsed}" -le "${RELEASE_TIMEOUT}" ]; do
  n1="$(count_conns "${AP1_CONTAINER}")"
  n2="$(count_conns "${AP2_CONTAINER}")"
  printf '%-12d %-12d %-18s %-18s\n' "$((SECONDS - fault_started_at))" "$((SECONDS - observation_started_at))" "${n1}" "${n2}"
  if [ "${n1}" -gt 0 ]; then observed_residual=1; fi
  # One optional, sequential management query only; never a success criterion.
  if [ "${elapsed}" -eq 0 ]; then
    if state_snapshot="$(docker exec -i "${DB_CONTAINER}" psql -U postgres -d appdb -Atq -F ' | ' -c "SELECT application_name, state, count(*) AS connections, count(*) FILTER (WHERE state='idle in transaction') AS idle_in_transaction FROM pg_stat_activity WHERE backend_type='client backend' AND application_name IN ('${AP1_CONTAINER}','${AP2_CONTAINER}') GROUP BY application_name, state ORDER BY application_name, state;" 2>/dev/null)"; then
      log_info "初回状態スナップショット (時系列の件数取得とは別時点): application_name | state | 接続数 | idle in transaction数"
      printf '%s\n' "${state_snapshot:-対象APの接続なし}"
      log_info "idle in transaction=トランザクションを開いたまま次の要求を待つ状態"
    else
      log_warn "追加の状態観測は取得できませんでした。既存の接続数・業務判定を継続します"
    fi
  fi
  if [ "${n1}" -eq 0 ] && [ "${elapsed}" -gt 0 ]; then
    released=0
    break
  fi
  if [ "${n1}" -eq 0 ] && [ "${elapsed}" -eq 0 ]; then
    log_warn "0秒時点で残留接続が0本です。障害再現に失敗した可能性があります"
    released=0
    break
  fi
  sleep "${INTERVAL}"
  elapsed=$((elapsed + INTERVAL))
done
echo "========================================================"

if [ "${released}" -ne 0 ]; then
  log_error "${RELEASE_TIMEOUT}秒以内に残留接続が解放されませんでした"
  log_error "設定が正しく適用されているか確認してください"
  exit 1
fi
log_ok "AP1由来の接続数=0 (直近のSQL観測)。AP2の業務確認へ進みます"
if [ "${observed_residual}" -eq 0 ]; then
  log_warn "残留あり→0の変化は未観察です。既存の成功条件は変更しませんが、自動解放の過程を確認済みとは扱えません"
else
  log_ok "AP1接続の残留あり→0を観測しました (観測経過=$((SECONDS - observation_started_at))秒)"
fi

current_phase="Phase 5: 業務回復の確認"
phase "${current_phase} — 接続数ではなく、DBの業務成功履歴で判定します"
log_info "ap-server-2 の業務回復を確認中..."
waited=0
while [ "${waited}" -lt 60 ]; do
  ok="$(psql_admin "SELECT count(*) FROM job_history
                    WHERE ap_name='${AP2_CONTAINER}'
                      AND status='success'
                      AND finished_at > now() - interval '30 seconds';")"
  if [ "${ok}" -gt 0 ]; then
    log_info "ap-server-2 の業務処理が回復しました(直近30秒の成功: ${ok} 件)"
    touch "${RETEST_MARKER}"
    log_ok "業務回復条件を満たしたため、再試験完了マーカーを記録しました"
    printf '\n---------------- 判定根拠 ----------------\n'
    log_ok "AP2=ACTIVE: Phase 3で現在プロセスを確認"
    log_ok "AP1由来接続=0: Phase 4の直近観測"
    log_ok "AP2の新しい業務成功: 直近30秒のjob_history success=${ok}件"
    log_info "直近30秒の移動窓であり、障害投入後だけに限定した累計ではありません (既存判定を維持)"
    if [ "${observed_residual}" -eq 0 ]; then
      log_warn "自動解放の遷移は未観察です。成功判定と観察の充足を区別してください"
    fi
    printf '[SUCCESS] === 再試験成功 === (既存の設定・切替・接続数・業務履歴の条件を満たしました)\n'
    exit 0
  fi
  sleep 5; waited=$((waited + 5))
done

log_error "ap-server-2 の業務回復を確認できませんでした"
docker logs --tail 20 "${AP2_CONTAINER}" || true
exit 1
