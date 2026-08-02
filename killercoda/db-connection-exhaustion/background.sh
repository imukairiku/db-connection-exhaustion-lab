#!/usr/bin/env bash
# =============================================================================
# Killercoda background: 演習環境の自動構築
# =============================================================================
set -Eeuo pipefail

REPO_URL="https://github.com/imukairiku/db-connection-exhaustion-lab.git"
REPO_DIR="/root/db-connection-exhaustion-lab"
LAB_DIR="/root/lab"
LOG_FILE="/var/log/lab-setup.log"

{
  echo "=== 演習環境構築開始: $(date) ==="

  until docker info >/dev/null 2>&1; do
    echo "Dockerデーモン待機中..."
    sleep 2
  done

  rm -rf "${REPO_DIR}"
  git clone --depth 1 "${REPO_URL}" "${REPO_DIR}"

  rm -rf "${LAB_DIR}"
  cp -r "${REPO_DIR}/lab" "${LAB_DIR}"
  chmod +x "${LAB_DIR}"/scripts/*.sh

  ln -sf "${LAB_DIR}/scripts/show-connections.sh"        /root/show-connections.sh
  ln -sf "${LAB_DIR}/scripts/apply-keepalive-setting.sh" /root/apply-keepalive-setting.sh
  ln -sf "${LAB_DIR}/scripts/retest.sh"                  /root/retest.sh
  ln -sf "${LAB_DIR}/scripts/reset-environment.sh"       /root/reset-environment.sh

  cd "${LAB_DIR}"
  ./scripts/create-failed-state.sh

  echo "=== 演習環境構築完了: $(date) ==="
  touch /opt/.lab-ready
} >> "${LOG_FILE}" 2>&1
