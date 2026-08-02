#!/usr/bin/env bash
# =============================================================================
# 演習スクリプト共通関数
#   - すべてのスクリプトから source して使用する
#   - 環境差(sudo要否、iptables可否)をここで吸収する
# =============================================================================
set -Eeuo pipefail

# ---- パス・定数 ----
COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${COMMON_SH_DIR}/.." && pwd)"
LAB_STATE_DIR="${LAB_STATE_DIR:-/tmp/lab-state}"
DROP_METHOD_FILE="${LAB_STATE_DIR}/drop-method"
RETEST_MARKER="${LAB_STATE_DIR}/retest-done"

DB_CONTAINER="db-server"
AP1_CONTAINER="ap-server-1"
AP2_CONTAINER="ap-server-2"

mkdir -p "${LAB_STATE_DIR}"

# ---- sudo要否の自動判定(Cloud Shell=一般ユーザー / Killercoda=root) ----
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

# ---- ログ出力 ----
log_info()  { printf '\033[32m[INFO]\033[0m  %s\n' "$*"; }
log_warn()  { printf '\033[33m[WARN]\033[0m  %s\n' "$*"; }
log_error() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }

on_error() {
  local exit_code=$?
  log_error "スクリプトが失敗しました: ${BASH_SOURCE[1]}:${BASH_LINENO[0]} (exit=${exit_code})"
  log_error "直前のコマンド: ${BASH_COMMAND}"
  exit "${exit_code}"
}
trap on_error ERR

# ---- Docker Compose ラッパ ----
compose() {
  docker compose --project-directory "${LAB_DIR}" "$@"
}

container_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"
}

container_pid() {
  docker inspect -f '{{.State.Pid}}' "$1"
}

container_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "notfound"
}

# ---- PostgreSQL操作(管理用: superuser予約枠で接続できる) ----
psql_admin() {
  local out
  if ! out="$(docker exec -i "${DB_CONTAINER}" psql -U postgres -d appdb -Atq -c "$1" 2>&1)"; then
    log_error "DBへの管理接続に失敗しました: ${out}"
    log_error "db-server の状態: $(container_state "${DB_CONTAINER}")"
    return 1
  fi
  printf '%s\n' "${out}"
}

count_conns() {
  psql_admin "SELECT count(*) FROM pg_stat_activity
              WHERE backend_type='client backend'
                AND application_name='$1';"
}

count_client_conns() {
  psql_admin "SELECT count(*) FROM pg_stat_activity
              WHERE backend_type='client backend';"
}

# ---- 待機ヘルパ ----
wait_for_db_healthy() {
  local timeout="${1:-90}" waited=0
  log_info "db-server のhealthy待機中..."
  while [ "${waited}" -lt "${timeout}" ]; do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' "${DB_CONTAINER}" 2>/dev/null || true)" = "healthy" ]; then
      log_info "db-server は healthy です"
      return 0
    fi
    sleep 3; waited=$((waited + 3))
  done
  log_error "db-server が ${timeout}秒以内にhealthyになりませんでした"
  docker logs --tail 20 "${DB_CONTAINER}" || true
  return 1
}

wait_for_conns_at_least() {
  local app="$1" need="$2" timeout="${3:-90}" waited=0 n=0
  log_info "${app} の接続数が ${need} 本以上になるまで待機中..."
  while [ "${waited}" -lt "${timeout}" ]; do
    n="$(count_conns "${app}")"
    if [ "${n}" -ge "${need}" ]; then
      log_info "${app} の接続数: ${n} 本(条件達成)"
      return 0
    fi
    sleep 3; waited=$((waited + 3))
  done
  log_error "${app} の接続数が ${timeout}秒以内に ${need} 本へ達しませんでした(現在 ${n} 本)"
  return 1
}

wait_for_log_pattern() {
  local name="$1" pattern="$2" timeout="${3:-60}" waited=0
  log_info "${name} のログに '${pattern}' が出るまで待機中..."
  while [ "${waited}" -lt "${timeout}" ]; do
    if docker logs --tail 100 "${name}" 2>&1 | grep -q "${pattern}"; then
      log_info "${name}: パターン検出"
      return 0
    fi
    sleep 3; waited=$((waited + 3))
  done
  log_error "${name} のログに '${pattern}' が ${timeout}秒以内に出力されませんでした"
  return 1
}

# =============================================================================
# 通信DROP(多段フォールバック)
# =============================================================================

_iptables_pair_add() {
  local chain="$1" ap1_ip="$2" db_ip="$3"
  local common_args=(-j DROP -m comment --comment lab-drop)
  ${SUDO} iptables -C "${chain}" -s "${ap1_ip}" -d "${db_ip}" "${common_args[@]}" 2>/dev/null \
    || ${SUDO} iptables -I "${chain}" 1 -s "${ap1_ip}" -d "${db_ip}" "${common_args[@]}"
  ${SUDO} iptables -C "${chain}" -s "${db_ip}" -d "${ap1_ip}" "${common_args[@]}" 2>/dev/null \
    || ${SUDO} iptables -I "${chain}" 1 -s "${db_ip}" -d "${ap1_ip}" "${common_args[@]}"
}

_iptables_pair_del() {
  local chain="$1" ap1_ip="$2" db_ip="$3"
  local common_args=(-j DROP -m comment --comment lab-drop)
  while ${SUDO} iptables -C "${chain}" -s "${ap1_ip}" -d "${db_ip}" "${common_args[@]}" 2>/dev/null; do
    ${SUDO} iptables -D "${chain}" -s "${ap1_ip}" -d "${db_ip}" "${common_args[@]}"
  done
  while ${SUDO} iptables -C "${chain}" -s "${db_ip}" -d "${ap1_ip}" "${common_args[@]}" 2>/dev/null; do
    ${SUDO} iptables -D "${chain}" -s "${db_ip}" -d "${ap1_ip}" "${common_args[@]}"
  done
}

_drop_is_effective() {
  local db_ip="$1"
  if docker exec "${AP1_CONTAINER}" timeout 3 bash -c \
      "cat < /dev/null > /dev/tcp/${db_ip}/5432" 2>/dev/null; then
    return 1
  fi
  return 0
}

apply_drop() {
  local ap1_ip db_ip ap1_pid
  ap1_ip="$(container_ip "${AP1_CONTAINER}")"
  db_ip="$(container_ip "${DB_CONTAINER}")"
  ap1_pid="$(container_pid "${AP1_CONTAINER}")"

  if [ -z "${ap1_ip}" ] || [ -z "${db_ip}" ]; then
    log_error "コンテナIPを取得できませんでした (ap1=${ap1_ip} db=${db_ip})"
    return 1
  fi
  log_info "通信DROP対象: ${AP1_CONTAINER}(${ap1_ip}) <-> ${DB_CONTAINER}(${db_ip})"

  if ${SUDO} iptables -nL DOCKER-USER >/dev/null 2>&1; then
    if _iptables_pair_add DOCKER-USER "${ap1_ip}" "${db_ip}" 2>/dev/null; then
      sleep 1
      if _drop_is_effective "${db_ip}"; then
        echo "host-docker-user" > "${DROP_METHOD_FILE}"
        log_info "DROP方式: host-docker-user(iptables DOCKER-USER)"
        return 0
      fi
      log_warn "DOCKER-USERルールが実効性なし(br_netfilter無効の可能性)。次の方式へ"
      _iptables_pair_del DOCKER-USER "${ap1_ip}" "${db_ip}" || true
    fi
  else
    log_warn "DOCKER-USERチェーンが利用できません。次の方式へ"
  fi

  if ${SUDO} iptables -nL FORWARD >/dev/null 2>&1; then
    if _iptables_pair_add FORWARD "${ap1_ip}" "${db_ip}" 2>/dev/null; then
      sleep 1
      if _drop_is_effective "${db_ip}"; then
        echo "host-forward" > "${DROP_METHOD_FILE}"
        log_info "DROP方式: host-forward(iptables FORWARD)"
        return 0
      fi
      log_warn "FORWARDルールが実効性なし。次の方式へ"
      _iptables_pair_del FORWARD "${ap1_ip}" "${db_ip}" || true
    fi
  fi

  if command -v nsenter >/dev/null 2>&1 && [ "${ap1_pid}" -gt 0 ]; then
    if ${SUDO} nsenter -t "${ap1_pid}" -n iptables -I OUTPUT -d "${db_ip}" -j DROP 2>/dev/null \
       && ${SUDO} nsenter -t "${ap1_pid}" -n iptables -I INPUT -s "${db_ip}" -j DROP 2>/dev/null; then
      sleep 1
      if _drop_is_effective "${db_ip}"; then
        echo "netns-iptables" > "${DROP_METHOD_FILE}"
        log_info "DROP方式: netns-iptables(nsenter + コンテナ内iptables)"
        return 0
      fi
      ${SUDO} nsenter -t "${ap1_pid}" -n iptables -D OUTPUT -d "${db_ip}" -j DROP 2>/dev/null || true
      ${SUDO} nsenter -t "${ap1_pid}" -n iptables -D INPUT -s "${db_ip}" -j DROP 2>/dev/null || true
    fi
  fi

  if command -v nsenter >/dev/null 2>&1 && command -v tc >/dev/null 2>&1 && [ "${ap1_pid}" -gt 0 ]; then
    ${SUDO} nsenter -t "${ap1_pid}" -n tc qdisc del dev eth0 root 2>/dev/null || true
    if ${SUDO} nsenter -t "${ap1_pid}" -n tc qdisc add dev eth0 root netem loss 100% 2>/dev/null; then
      sleep 1
      if _drop_is_effective "${db_ip}"; then
        echo "netns-tc" > "${DROP_METHOD_FILE}"
        log_info "DROP方式: netns-tc(tc netem loss 100%)"
        log_warn "netemはDROPと厳密には同一ではありません(制約はdocsを参照)"
        return 0
      fi
      ${SUDO} nsenter -t "${ap1_pid}" -n tc qdisc del dev eth0 root 2>/dev/null || true
    fi
  fi

  log_error "利用可能な通信DROP方式がありません。"
  log_error "この環境では本演習の障害再現ができません。"
  log_error "docs/environment-differences.md の制約を確認してください。"
  return 1
}

clear_drop() {
  local ap1_ip db_ip ap1_pid
  ap1_ip="$(container_ip "${AP1_CONTAINER}" 2>/dev/null || true)"
  db_ip="$(container_ip "${DB_CONTAINER}" 2>/dev/null || true)"
  ap1_pid="$(container_pid "${AP1_CONTAINER}" 2>/dev/null || echo 0)"

  if [ -n "${ap1_ip}" ] && [ -n "${db_ip}" ]; then
    if ${SUDO} iptables -nL DOCKER-USER >/dev/null 2>&1; then
      _iptables_pair_del DOCKER-USER "${ap1_ip}" "${db_ip}" || true
    fi
    if ${SUDO} iptables -nL FORWARD >/dev/null 2>&1; then
      _iptables_pair_del FORWARD "${ap1_ip}" "${db_ip}" || true
    fi
    if command -v nsenter >/dev/null 2>&1 && [ "${ap1_pid}" -gt 0 ]; then
      ${SUDO} nsenter -t "${ap1_pid}" -n iptables -D OUTPUT -d "${db_ip}" -j DROP 2>/dev/null || true
      ${SUDO} nsenter -t "${ap1_pid}" -n iptables -D INPUT -s "${db_ip}" -j DROP 2>/dev/null || true
      ${SUDO} nsenter -t "${ap1_pid}" -n tc qdisc del dev eth0 root 2>/dev/null || true
    fi
  fi
  rm -f "${DROP_METHOD_FILE}"
  log_info "通信DROPルールを解除しました(全方式クリーンアップ済み)"
}
