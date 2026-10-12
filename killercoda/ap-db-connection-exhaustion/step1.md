## 1. 切替状況を調べる

目的：障害後の現用APと、切替を行った主体を調べます。環境構築と障害投入はScenario開始時に自動実行されます。

```bash
cd /root/ap-db-connection-exhaustion-lab
python3 -m json.tool artifacts/phase7/failover-state.json
tail -n 10 artifacts/phase7/monitor-events.jsonl
PROJECT="phase7-$(cut -d- -f1 /proc/sys/kernel/random/boot_id)"
sudo docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format 'table {{.Names}}\t{{.Status}}'
```

観察：`status=ACTIVE`、`active_service=ap-server-2`、監視イベントの検知→起動→ACTIVEの順序、AP1の`Paused`状態を照合します。
ファイルがまだ無ければ背景セットアップ完了を待ってから同じブロックを再実行してください。ここでは接続を変更しません。
