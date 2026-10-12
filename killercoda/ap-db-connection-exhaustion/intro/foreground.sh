#!/usr/bin/env bash
set -euo pipefail
echo "新Scenarioの環境を自動構築しています。数分お待ちください。"
for attempt in $(seq 1 200); do
  if [ -f /opt/ap-db-scenario-failed ]; then
    echo "構築に失敗しました。ログを確認してください："
    echo "tail -n 60 /var/log/ap-db-scenario-setup.log"
    exit 1
  fi
  if [ -f /opt/ap-db-scenario-ready ]; then
    echo "準備完了。Step 1から調査を開始してください。"
    echo "作業ディレクトリ：/root/ap-db-connection-exhaustion-lab"
    exit 0
  fi
  sleep 3
done
echo "構築が600秒以内に完了しませんでした。"
echo "tail -n 60 /var/log/ap-db-scenario-setup.log"
exit 1
