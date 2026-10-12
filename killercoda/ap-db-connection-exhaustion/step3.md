## 3. DB側の状況を調べる

目的：APの失敗が、PostgreSQL側の実際の接続制限と対応しているか調べます。

```bash
cd /root/ap-db-connection-exhaustion-lab
PROJECT="phase7-$(cut -d- -f1 /proc/sys/kernel/random/boot_id)"
DB=$(sudo docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=db-server')
sudo docker exec "$DB" psql -U lab -d lab -c "SHOW max_connections"
sudo docker exec "$DB" psql -U lab -d lab -c "SHOW superuser_reserved_connections"
sudo docker exec "$DB" psql -U lab -d lab -c "SELECT count(*) AS client_backends FROM pg_stat_activity WHERE backend_type='client backend'"
sudo docker logs "$DB" 2>&1 | grep -E 'FATAL:.*(too many clients|remaining connection slots)' | tail -n 12
```

観察：接続上限、管理者用予約枠、観測時の接続数、実際のDBログの`FATAL`を比較します。
`count(*)`には、この確認に使うpsql自身の接続も一時的に含まれます。
どの接続が枠を使っているかは、次のStepで分類します。
