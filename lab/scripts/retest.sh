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

log_info "=== 再試験を開始します ==="

# 1. 恒久対策の事前チェック
timeout_val="$(psql_admin 'SHOW idle_in_transaction_session_timeout;')"
if [ "${timeout_val}" != "30s" ]; then
  log_error "idle_in_transaction_session_timeout が未適用です (現在値: ${timeout_val})"
  log_error "先に ./apply-keepalive-setting.sh を実行してください"
  exit 1
fi
log_info "恒久対策設定を確認しました (idle_in_transaction_session_timeout = ${timeout_val})"

rm -f "${RETEST_MARKER}"

"${SCRIPTS_DIR}/reset-environment.sh"

"${SCRIPTS_DIR}/inject-failure.sh"

wait_for_log_pattern "${AP2_CONTAINER}" "PROMOTED to ACTIVE" 40

echo ""
echo "========================================================"
echo " 接続数の推移(idle-in-transaction接続の自動解放の観察)"
echo " 期待: 約30〜40秒で ap-server-1 の残留接続が 0 になる"
echo "========================================================"
elapsed=0
released=1
while [ "${elapsed}" -le "${RELEASE_TIMEOUT}" ]; do
  n1="$(count_conns "${AP1_CONTAINER}")"
  n2="$(count_conns "${AP2_CONTAINER}")"
  printf '%3d秒  ap-server-1=%-3s ap-server-2=%-3s\n' "${elapsed}" "${n1}" "${n2}"
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
log_info "ap-server-1 由来の残留接続が自動解放されました"

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
    log_info "=== 再試験成功 ==="
    exit 0
  fi
  sleep 5; waited=$((waited + 5))
done

log_error "ap-server-2 の業務回復を確認できませんでした"
docker logs --tail 20 "${AP2_CONTAINER}" || true
exit 1