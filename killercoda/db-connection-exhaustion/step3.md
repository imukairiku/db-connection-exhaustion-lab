# Step 3: 残留接続の終了と業務復旧(暫定復旧)

原因は、停止済み `ap-server-1` 由来の残留接続によるDB接続枯渇でした。
暫定復旧として、**残留接続だけ**を終了します。

## 問4: 暫定復旧

管理用接続(postgresユーザー)から実施します。

```````````````````bash
docker exec -it db-server psql -U postgres -d appdb
``````````````````{{exec}}

**必ず先に対象を確認**してから終了してください。
`ap-server-2` の接続や自分自身の管理用接続を誤って終了しないためです。

`````````````````sql
-- 対象の確認(application_nameで絞る)
SELECT pid, application_name, client_addr, state
FROM pg_stat_activity
WHERE application_name = 'ap-server-1';
````````````````{{copy}}

```````````````sql
-- ap-server-1 由来の接続のみ終了
SELECT
    pid,
    pg_terminate_backend(pid) AS terminated
FROM pg_stat_activity
WHERE application_name = 'ap-server-1'
  AND pid <> pg_backend_pid();
``````````````{{copy}}

<details>
<summary>ヒント(WHERE句の意味)</summary>

- `application_name = 'ap-server-1'` : 停止済みAP由来の接続だけに限定
- `pid <> pg_backend_pid()` : 自分自身(この管理セッション)を除外

`pg_terminate_backend` はPID単位で接続を強制終了します。
条件を誤ると稼働中の `ap-server-2` の業務処理まで切断してしまうため、
実運用でも「SELECTで対象確認 → 同じWHERE句で終了」の手順を徹底します。

</details>

## 問5: 復旧確認

psqlを `\q` で抜けて、`ap-server-2` の業務が回復したかを確認します。

`````````````bash
docker logs --tail 20 ap-server-2
````````````{{exec}}

```````````bash
/root/show-connections.sh
``````````{{exec}}

## 期待する確認結果

- `ap-server-1` の接続が 0 本になっている
- `ap-server-2` のログに `job SUCCESS` が出力され始めている
  (ワーカーのリトライ間隔があるため、数秒〜10秒程度待ってから確認してください)

## 次のステップへ進む条件

- `ap-server-1` 由来の残留接続が 0 本であること
- `ap-server-2` の業務処理が成功していること

確認できたら CHECK を押してください。
