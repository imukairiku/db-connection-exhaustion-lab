調査結果をもとに、業務を回復させます。操作前に「何を終了し、何を残すか」を決めましょう。

**学習目標：影響範囲を考えて復旧対象を限定し、操作後の業務成功まで確認する。**

## 1. 復旧方法を判断する

| 方法 | 影響の違い |
|---|---|
| DB全体を再起動する | 正常な接続や処理中のトランザクションにも影響する |
| 特定の接続だけを終了する | 対象を正しく選べば、他の接続への影響を抑えられる |

今回は、停止済みAP1の接続だけを終了します。DB全体の再起動は行いません。

## 2. SELECTで対象を確認してから終了する

まず、終了対象の一覧を表示します。`pid`はDB側でその接続を担当するプロセスの識別番号です。

```bash
cd /root/lab
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT pid, application_name, client_addr, state, backend_start FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = 'ap-server-1' AND pid <> pg_backend_pid() ORDER BY pid;"
```{{exec}}

AP2や調査用接続が含まれず、Step 2で調べた対象と一致することを確認してから、次を実行してください。固定のPIDは指定せず、同じ条件で現在の接続を選び直します。

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT pid, pg_terminate_backend(pid) AS terminated FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = 'ap-server-1' AND pid <> pg_backend_pid();"
```{{exec}}

`pg_terminate_backend`は指定PIDへ接続終了を要求します。未確定の処理は取り消されます。`t`は終了要求の送信成功を示すため、実際に接続が消えたかは次の確認も必要です。`pg_backend_pid()`は今の管理接続自身のPIDで、それを対象から除外しています。

## 3. 接続数と業務結果を確かめる

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT count(*) AS ap1_connections FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = 'ap-server-1';"
/root/lab/scripts/show-connections.sh
docker logs --since 1m ap-server-2 2>&1 | tail -n 20
```{{exec}}

AP1の接続数が0になり、AP2のログに新しい `job SUCCESS` が出るか確認します。再試行と業務処理に時間がかかるため、すぐに成功が見えなければ10〜30秒ほど待って同じ確認を繰り返してください。

DBに記録された直近の業務成功も確認できます。

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT count(*) AS recent_ap2_success FROM job_history WHERE ap_name = 'ap-server-2' AND status = 'success' AND finished_at > now() - interval '2 minutes';"
```{{exec}}

## 出力から考えること

- 終了する接続を限定したことで、どの接続を守れましたか。
- AP1が同じ障害を起こした場合、今回の操作だけで再発を防げるでしょうか。

<details>
<summary>ヒント1：WHERE句が操作の範囲を決める</summary>

確認用SELECTと終了用SQLのWHERE句を比べてください。AP名を絞る条件を外すと、正常なAP2の接続も対象になり得ます。

</details>

<details>
<summary>ヒント2：操作成功と業務成功を区別する</summary>

終了要求が成功しても、それだけでは復旧完了とはいえません。AP1接続0と、AP2の新しい成功ログ・業務履歴を合わせて確認します。接続を一度消す操作は、次の残留を防ぐ仕組みにはなりません。

</details>

## CHECK前の確認

- 対象をSELECTで確認してから、AP1の接続だけを終了した。
- AP1接続が0で、AP2の直近の業務成功を確認した。
- 今回の操作が暫定復旧である理由を説明できる。

CHECKは接続数と最近の業務成功を判定します。復旧操作の影響範囲も自分で確認してから進んでください。
