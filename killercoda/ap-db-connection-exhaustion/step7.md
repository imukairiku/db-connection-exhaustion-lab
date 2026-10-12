## 7. 業務を再試験する

目的：復旧後に**別の新しい**業務要求を送信し、DBへの接続とCOMMITを確認してfinishへ進みます。

```bash
cd /root/ap-db-connection-exhaustion-lab
sudo bash scripts/scenario-business-check.sh
PROJECT="phase7-$(cut -d- -f1 /proc/sys/kernel/random/boot_id)"
DB=$(sudo docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=db-server')
RID=$(python3 -c 'import json; print(json.load(open("artifacts/phase7/current.json"))["last_business"]["request_id"])')
sudo docker exec "$DB" psql -U lab -d lab -c "SELECT request_id, ap_name FROM business_results WHERE request_id='$RID'"
sudo docker exec "$DB" psql -U lab -d lab -c "SELECT application_name, count(*) FROM pg_stat_activity WHERE application_name IN ('ap-server-1','ap-server-2','management-1','management-2') GROUP BY application_name ORDER BY application_name"
```

観察：新しい`request_id`に対応する`ap-server-2`のCOMMIT済み行が現れ、旧AP接続は0件、新APと管理接続は維持されます。verifyはDB再起動なしも再確認します。

finish到達後にもう一度演習したい場合だけ、以下で正常状態へresetし、同じ障害を再注入できます。Step 7のverify前には実行しないでください。これはStep 5の復旧手段ではありません。resetすると現在の演習状態とDB設定は初期化されます。

```bash
cd /root/ap-db-connection-exhaustion-lab
sudo bash scripts/scenario-reset.sh
sudo bash scripts/scenario-inject.sh
```
