## 5. 暫定復旧する

目的：Step 4で識別した旧APの接続だけを終わらせ、AP2の業務を回復させます。DB全体は再起動しません。

次のブロックはAP1の現在のIPを読み直し、対象PID・出所・開始時刻を直前に再表示します。出所がStep 4の観察と一致する場合だけ、最後の終了処理まで進んでください。

```bash
cd /root/ap-db-connection-exhaustion-lab
PROJECT="phase7-$(cut -d- -f1 /proc/sys/kernel/random/boot_id)"
DB=$(sudo docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=db-server')
AP1=$(sudo docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=ap-server-1')
AP1_IP=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$AP1")
sudo docker exec "$DB" psql -U lab -d lab -c "SELECT pid, application_name, client_addr, backend_start, state FROM pg_stat_activity WHERE application_name='ap-server-1' AND client_addr='$AP1_IP'::inet ORDER BY pid"
```

表示された対象がAP1の接続だけなら、次を実行します。SQL実行時にも`application_name`と`client_addr`を再照合するため、既に消滅した対象は選ばれず、新AP・管理用接続は終了しません。固定PIDは使いません。

```bash
cd /root/ap-db-connection-exhaustion-lab
PROJECT="phase7-$(cut -d- -f1 /proc/sys/kernel/random/boot_id)"
DB=$(sudo docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=db-server')
AP1=$(sudo docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=ap-server-1')
AP1_IP=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$AP1")
sudo docker exec "$DB" psql -U lab -d lab -c "WITH targets AS MATERIALIZED (SELECT pid FROM pg_stat_activity WHERE application_name='ap-server-1' AND client_addr='$AP1_IP'::inet AND pid<>pg_backend_pid()) SELECT pid, pg_terminate_backend(pid) AS terminated FROM targets"
sudo docker exec "$DB" psql -U lab -d lab -c "SELECT application_name, count(*) FROM pg_stat_activity WHERE application_name IN ('ap-server-1','ap-server-2','management-1','management-2') GROUP BY application_name ORDER BY application_name"
sudo bash scripts/scenario-business-check.sh
```

観察：集計に旧APの行が表示されなければ旧AP接続は0件です。新AP・管理用接続は残り、最後のコマンドは新しい`request_id`の業務COMMITを報告します。
verifyは接続と業務結果に加え、DBコンテナとpostmasterが開始時から変わっていないことを確認します。
