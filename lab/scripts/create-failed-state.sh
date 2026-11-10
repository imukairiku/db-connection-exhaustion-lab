#!/usr/bin/env bash
# =============================================================================
# 演習開始状態の自動構築
# =============================================================================
set -Eeuo pipefail

# Learner invocations get a concise display. The startup supervisor already
# captures detailed logs and consumes startup_stage messages, so keep its path.
if [ "${LAB_STARTUP_PROGRESS:-0}" != 1 ] && [ "${LAB_REBUILD_INTERNAL:-0}" != 1 ]; then
  diagnostic_log=/var/log/lab-setup.log
  if ! exec {diagnostic_fd}>>"${diagnostic_log}"; then
    printf '[ERROR] 診断ログを保存できません: %s\n' "${diagnostic_log}" >&2
    exit 1
  fi
  printf '\n=== Exercise rebuild: %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&"${diagnostic_fd}"
  printf '[INFO] 演習環境を再構築しています...\n'
  # FD 3 carries only the explicitly selected learner progress message.
  if LAB_REBUILD_INTERNAL=1 bash "${BASH_SOURCE[0]}" "$@" 3>&1 >&"${diagnostic_fd}" 2>&1; then
    printf '[OK]   演習環境の準備が完了しました。\n\nStep 1から調査を開始してください。\n'
  else
    rebuild_rc=$?
    printf '[ERROR] 演習環境の準備に失敗しました (終了コード: %s)。\n' "${rebuild_rc}" >&2
    printf '診断ログ: %s\n' "${diagnostic_log}" >&2
    exit "${rebuild_rc}"
  fi
  exit 0
fi

source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/common.sh"

SCRIPTS_DIR="${COMMON_SH_DIR}"
NEED_LEFTOVER=8
MAX_ATTEMPTS=3

assert_lab_container() {
  local name="$1" ownership
  ownership="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}' "${name}")"
  if [ "${ownership}" != "reliability-lab|${name}" ]; then
    log_error "演習専用コンテナであることを確認できません: ${name} (${ownership})"
    return 1
  fi
}

restore_initial_timeout() {
  local waited=0
  assert_lab_container "${DB_CONTAINER}"
  psql_admin "ALTER SYSTEM SET idle_in_transaction_session_timeout = '0';" >/dev/null
  psql_admin "SELECT pg_reload_conf();" >/dev/null
  while [ "${waited}" -lt 10 ]; do
    if [ "$(psql_admin 'SHOW idle_in_transaction_session_timeout;')" = 0 ]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log_error "演習開始用のタイムアウト設定へ戻せませんでした"
  return 1
}

# Container restarts retain old logs; require capacity errors from this injection.
wait_for_current_capacity_error() {
  local deadline=$((SECONDS + 60)) snapshot
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    if snapshot="$(docker logs --since "${fault_log_since}" "${AP2_CONTAINER}" 2>&1)" &&
       grep -e 'DB connection failed' <<< "${snapshot}" >/dev/null &&
       grep -e 'remaining connection slots' -e 'too many clients' <<< "${snapshot}" >/dev/null; then
      return 0
    fi
    sleep 3
  done
  log_error "今回の障害投入後のAP2接続枠不足エラーを確認できませんでした"
  return 1
}

log_info "=== 演習開始状態(障害発生済み)の構築を開始します ==="

# Rebuilding an exercise invalidates the previous retest, even if rebuilding fails.
rm -f "${RETEST_MARKER}"

# setup.sh assumes AP1 can work. Restore an existing, possibly paused exercise
# before calling it; leave the original clean-install path intact.
if docker inspect "${DB_CONTAINER}" >/dev/null 2>&1; then
  log_warn "やり直しにより現在の接続・恒久対策設定・再試験状態を変更します"
  assert_lab_container "${DB_CONTAINER}"
  compose up -d "${DB_CONTAINER}"
  wait_for_db_healthy 120
  restore_initial_timeout
  if docker inspect "${AP1_CONTAINER}" >/dev/null 2>&1 &&
     docker inspect "${AP2_CONTAINER}" >/dev/null 2>&1; then
    assert_lab_container "${AP1_CONTAINER}"
    assert_lab_container "${AP2_CONTAINER}"
    "${SCRIPTS_DIR}/start-normal-load.sh"
  fi
fi

"${SCRIPTS_DIR}/setup.sh"

# Disable the Step 4 mitigation so residual connections remain observable again.
restore_initial_timeout

attempt=1
while [ "${attempt}" -le "${MAX_ATTEMPTS}" ]; do
  log_info "--- 障害投入 試行 ${attempt}/${MAX_ATTEMPTS} ---"

  startup_stage begin normal
  "${SCRIPTS_DIR}/start-normal-load.sh"

  wait_for_conns_at_least "${AP1_CONTAINER}" "${NEED_LEFTOVER}" 90
  startup_stage end normal

  startup_stage begin scenario
  if [ "${LAB_REBUILD_INTERNAL:-0}" = 1 ] && [ "${attempt}" -eq 1 ]; then
    printf '[INFO] 障害シナリオを準備しています...\n' >&3
  fi
  fault_log_since="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
  "${SCRIPTS_DIR}/inject-failure.sh"

  wait_for_ap_active "${AP2_CONTAINER}" 40

  sleep 5
  leftover="$(count_conns "${AP1_CONTAINER}")"
  log_info "ap-server-1 由来の残留接続: ${leftover} 本"
  if [ "${leftover}" -ge "${NEED_LEFTOVER}" ]; then
    break
  fi
  log_warn "残留接続が ${NEED_LEFTOVER} 本未満のためリトライします"
  startup_stage retry scenario
  attempt=$((attempt + 1))
  if [ "${attempt}" -gt "${MAX_ATTEMPTS}" ]; then
    log_error "障害状態の構築に失敗しました(残留接続不足)"
    exit 1
  fi
done

wait_for_current_capacity_error
startup_stage end scenario

startup_stage begin ready
[ "$(container_state "${DB_CONTAINER}")" = running ]
[ "$(docker inspect -f '{{.State.Health.Status}}' "${DB_CONTAINER}")" = healthy ]
[ "$(container_state "${AP1_CONTAINER}")" = paused ]
[ "$(container_state "${AP2_CONTAINER}")" = running ]
wait_for_ap_active "${AP2_CONTAINER}" 5
[ "$(count_conns "${AP1_CONTAINER}")" -ge "${NEED_LEFTOVER}" ]
# Gather fallible observations before announcing completion.
final_ap1_state="$(container_state "${AP1_CONTAINER}")"
final_ap2_state="$(container_state "${AP2_CONTAINER}")"
final_leftover="$(count_conns "${AP1_CONTAINER}")"
final_total="$(count_client_conns)"
[ "${final_ap1_state}" = paused ]
[ "${final_ap2_state}" = running ]
[ "${final_leftover}" -ge "${NEED_LEFTOVER}" ]
log_info "=== 演習開始状態の構築完了 ==="
log_info "  ap-server-1 : ${final_ap1_state}(通信断+pause)"
log_info "  ap-server-2 : ${final_ap2_state}(昇格済み・接続エラー発生中)"
log_info "  残留接続    : ${final_leftover} 本"
log_info "  総接続数    : ${final_total} 本(max_connections=20)"
startup_stage end ready
