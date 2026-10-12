## 2. 業務影響を確認する

目的：切替先APで、どの業務要求がDBに接続でき、どれが失敗したかを調べます。

```bash
cd /root/ap-db-connection-exhaustion-lab
PROJECT="phase7-$(cut -d- -f1 /proc/sys/kernel/random/boot_id)"
AP2=$(sudo docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=ap-server-2')
sudo docker logs "$AP2" 2>&1 | grep -E 'CONNECT_ATTEMPT|CONNECTION_FAILED|RETRY_SCHEDULED|DB_CONNECTED|BUSINESS_COMMITTED' | head -n 30
sudo docker exec "$AP2" python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/state').read().decode())" | python3 -m json.tool
```

観察：同じAP2で`DB_CONNECTED`と`CONNECTION_FAILED`が混在し、失敗後に`RETRY_SCHEDULED`が出ていること、`/state`の`connected`と`connection_failures`がともに1以上であることを確認します。
まだ原因は決めつけず、次にDB側の事実と突き合わせます。
