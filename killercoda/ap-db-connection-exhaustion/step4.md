## 4. 接続を識別する

目的：現在のDB接続を出所ごとに識別し、障害の前から残っている接続を見つけます。**まだ切断しません。**

```bash
cd /root/ap-db-connection-exhaustion-lab
PROJECT="phase7-$(cut -d- -f1 /proc/sys/kernel/random/boot_id)"
DB=$(sudo docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=db-server')
AP1=$(sudo docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=ap-server-1')
AP2=$(sudo docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=ap-server-2')
sudo docker inspect -f '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$AP1" "$AP2"
sudo docker exec "$DB" psql -U lab -d lab -c "SELECT pid, application_name, client_addr, client_port, state, backend_start, state_change FROM pg_stat_activity WHERE backend_type='client backend' ORDER BY application_name, backend_start"
sudo docker exec "$DB" ss -Hnt state established '( sport = :5432 )'
```

観察：`application_name`、APコンテナのIPと`client_addr`、接続開始の`backend_start`、最終状態変更の`state_change`を照合します。
`ss`の相手IP・ポートとDB側セッションを見比べ、AP1・AP2・管理用の接続を区別してください。
