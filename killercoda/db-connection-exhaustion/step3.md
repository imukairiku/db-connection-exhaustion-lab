Step 2では、停止したAP1由来のDB接続が残り、接続枠を圧迫していることを確認しました。これから業務を復旧します。まず、現在稼働しているAP2の業務や管理用接続への影響を考え、「何を終了し、何を残すか」を決めましょう。

**学習目標：AP2への影響を抑えながらAP1由来の残留接続だけを終了し、新しい業務の成功を根拠に復旧を判断する。**

## 1. 復旧方法を判断する

| 方法 | 影響の違い |
|---|---|
| DB全体を再起動する | 正常な接続や処理中のトランザクションにも影響する |
| 特定の接続だけを終了する | 対象を正しく選べば、他の接続への影響を抑えられる |

どちらの方法なら、正常なAP2の接続や処理を残せるでしょうか。操作の影響範囲を説明してから進んでください。本演習ではDB全体の再起動は行いません。

## 2. SELECTで終了対象を確認する

まず、Step 2で特定したAP1由来の接続を一覧にします。ここではまだ接続を終了しません。

```bash
cd /root/lab
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT pid, application_name, client_addr, state, backend_start FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = 'ap-server-1' AND pid <> pg_backend_pid() ORDER BY pid;"
```{{exec}}

`pid`は接続を担当するDBプロセスの識別番号、`backend_start`は接続開始時刻です。`application_name`・`client_addr`・`state`をStep 2の結果と照合し、AP1の接続だけであることを確認します。

`WHERE`句は対象を選ぶ条件です。

- `backend_type = 'client backend'`：DB内部の処理ではなく、クライアント接続を選ぶ。
- `application_name = 'ap-server-1'`：AP1が名乗る接続だけを選ぶ。
- `pid <> pg_backend_pid()`：SQLを実行している管理接続自身を除く（`<>`は「等しくない」）。

AP2や管理用接続が含まれているなど、想定と違う場合は次の操作へ進まないでください。

## 3. 確認した条件で残留接続を終了する

固定PIDは使わず、同じ条件で現在の接続を選び直して終了を要求します。AP1が引き続き停止していることと、直前のSELECTの対象が正しいことを確認して実行してください。

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT pid, pg_terminate_backend(pid) AS terminated FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = 'ap-server-1' AND pid <> pg_backend_pid();"
```{{exec}}

`pg_terminate_backend(pid)`は指定したDBプロセスへ接続終了を要求します。対象接続の未確定の処理は取り消されます。`terminated = t`は終了要求の送信成功を示しますが、それだけで接続の消滅や業務復旧を確認したことにはなりません。

## 4. 接続数と業務結果を確かめる

次を実行する前に、復旧操作を行った時刻を控えておきましょう。

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT count(*) AS ap1_connections FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = 'ap-server-1';"
/root/lab/scripts/show-connections.sh
docker logs --since 1m ap-server-2 2>&1 | tail -n 20
```{{exec}}

AP1接続が0本になったか、接続一覧にAP2が見えるか、AP2のログに復旧操作後の新しい `job SUCCESS` が出るかを確認します。AP2は要求ごとに接続を作成・終了するため、本数が一定である必要はありません。

再試行と業務処理に時間がかかります。すぐに成功が見えなければ10〜30秒ほど待ち、この確認と次の履歴確認をもう一度実行してください。成功が確認できないまま完了とは判断しません。

DBに記録された直近の業務成功も確認します。

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT count(*) AS recent_ap2_success FROM job_history WHERE ap_name = 'ap-server-2' AND status = 'success' AND finished_at > now() - interval '2 minutes';"
```{{exec}}

`recent_ap2_success`が1件以上であることを確認します。ただし、この集計は操作前の成功を含む場合があるため、操作後の日時・要求IDの `job SUCCESS` と併せて判断してください。接続一覧はその時点の状態であり、それだけで「正常接続を一度も切っていない」ことまでは証明できません。実行したWHERE句と操作前後の出力も照合します。

## 5. 出力から考えること

- **問1：なぜPostgreSQL全体を再起動せず、AP1の接続だけを終了したのでしょうか？** 正常なAP2の業務への影響を考えてください。
- **問2：今回の復旧作業が成功したと判断できる根拠は何でしょうか？** `terminated = t`以外に、接続数・ログ・履歴から根拠を挙げてください。
- **問3：今回の対応だけで同じ障害の再発を防げるでしょうか？** 今回の操作が変えたものと、変えていないものを考えてください。

<details>
<summary>ヒント1：WHERE句が操作の範囲を決める</summary>

確認用SELECTと終了用SQLのWHERE句を比べてください。条件を外すと、対象はどう広がるでしょうか。操作対象に含まれない接続にも注目します。

</details>

<details>
<summary>ヒント2：操作成功と業務成功を区別する</summary>

接続終了要求が成功したことと、業務が再び処理できることは別です。利用者にとっての復旧を示す記録はどれでしょうか。また、今回のSQLに次の障害へ備える設定変更が含まれているか振り返ってください。

</details>

<details>
<summary>模範解答：自分で3問を考えてから開く</summary>

自分のSQL出力とログを照合してください。以下の値は確認すべき条件であり、あなたの環境で観測済みの結果を示すものではありません。

### 問1：復旧操作の影響範囲

**答え：PostgreSQL全体の再起動は正常な接続にも影響するため、AP1由来の接続だけを終了する方が影響を限定できる。**

根拠は、確認用SELECTと終了用SQLに共通する次の条件です。

```sql
WHERE backend_type = 'client backend'
  AND application_name = 'ap-server-1'
  AND pid <> pg_backend_pid()
```

AP2の接続はAP名の条件に合わず、対象から除外されます。管理接続自身も明示的に除外しています。本演習ではAP名を識別に使えますが、実運用では `application_name` だけを信用せず、接続元IPや接続ユーザーなども確認して対象を選びます。

### 問2：暫定復旧の成功を示す根拠

**答え：AP1由来の接続が0本になり、AP2の新しい業務処理が成功していれば、今回の暫定復旧は成功と判断できる。**

根拠として次の結果を組み合わせます。

- `pg_stat_activity`を調べた `ap1_connections` が0。
- AP2のログに、復旧操作後の新しい `job SUCCESS:` がある。
- `job_history`の直近の `success` が1件以上あり、新しい成功ログとも整合する。

`terminated = t`は終了要求の送信結果であり、AP2が接続できて業務をCOMMITした証拠ではありません。AP2・管理接続を対象にしていないこともWHERE句と接続一覧で確認します。件数は変動するため、固定の成功件数やAP2接続数を期待しません。

### 問3：再発を防げるか

**答え：今回の操作だけでは再発を防げない。**

根拠は、実行したSQLが `pg_terminate_backend` による現在の接続の終了であり、切断検知やタイムアウトの設定を変更していないことです。

この操作は現在残っている接続を解消するもので、次の障害で接続が残ることを自動的に防ぐ機能ではありません。再発防止には、残留接続の自動解放やタイムアウト設計が必要です。

### まとめ

AP1の残留接続だけを終了して影響範囲を限定し、AP1接続0本とAP2の新しい業務成功を根拠に復旧を判断しました。ただし、同じ原因での再発を防ぐ仕組みはまだ導入していません。したがって今回の対応は**暫定復旧**です。

</details>

## CHECK前の確認

- 対象をSELECTで確認してから終了した。
- AP1接続が0本になった。
- AP2の新しい業務成功を確認した。
- 暫定復旧と恒久対策の違いを説明できる。

CHECKはAP1接続0本と最近のAP2業務成功を判定します。操作の影響範囲や、成功が操作後の新しいものであることも自分で確認してください。既存CHECKはDB再起動の有無や正常接続の保持までは判定しないため、CHECK成功だけで操作方法の正しさを保証するものではありません。

CHECK後はStep 4へ進み、残留接続を自動解放する恒久対策と再試験に取り組みます。
