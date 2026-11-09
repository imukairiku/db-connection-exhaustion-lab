Step 2で特定した問題を解消し、業務を回復させます。正常に稼働しているAP2や管理用接続への影響を抑えるには、どの復旧方針が適切でしょうか。

**操作の目的：復旧対象を限定し、操作後の接続数と新しい業務成功を根拠に復旧を判断する。**

## 考える問題

1. DB全体の再起動と、特定の接続だけを終了する方法では、影響範囲がどう違いますか。
2. 何を条件に対象を選び、どの出力を確認してから操作しますか。復旧成功の根拠も考えてください。
3. 今回の操作だけで、次の障害での再発も防げますか。

**安全上の注意：必ずSELECTで対象を確認してから終了してください。** 正常なAP2・管理用接続を終了しないこと、固定PIDや全接続の一括終了を使わないことを守ります。本演習ではDB全体を再起動しません。対象が不明なら、終了せず模範解答の確認手順を読んでください。

<details>
<summary>ヒント1：対象と影響範囲を決める</summary>

`pg_stat_activity` を `SELECT` し、`WHERE` で対象を絞る方法を考えます。`pg_terminate_backend` は指定したDBプロセスへ接続終了を要求する関数です。終了対象と、残すべき接続を先に区別してください。

</details>

<details>
<summary>ヒント2：確認と操作に同じ条件を使う</summary>

接続の種類・アプリ名・管理接続自身の除外を条件にします。確認用SELECTの出力を見てから、終了用SQLでも同じ条件で選び直してください。終了要求の成功と業務回復は別なので、接続数と新しい業務記録を確認します。

</details>

<details>
<summary>模範解答：実行コマンド・SQL（自分で考えてから開く）</summary>

以下を上から順に実行します。開閉だけでは実行されません。出力を確認し、次の操作が安全か判断してから各コードの実行ボタンを押してください。「判断と技術的な解説」は別に開くまで表示されません。

### 1. 終了対象をSELECTで確認する

```bash
cd /root/lab
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT pid, application_name, client_addr, state, backend_start FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = 'ap-server-1' AND pid <> pg_backend_pid() ORDER BY pid;"
```{{exec}}

`pid` は接続を担当するDBプロセスの識別番号、`backend_start` は接続開始時刻です。`application_name`・`client_addr`・`state` をStep 2の調査結果と照合し、AP1の対象だけが表示されることを確認します。

`WHERE` はクライアント接続・AP1の名前・管理接続自身の除外を条件にしています。想定外の行がある場合は、次の終了操作へ進まないでください。

### 2. 確認した条件で対象を終了する

AP1が引き続き停止していることを確認し、固定PIDではなく同じ条件で現在の対象を選び直します。**先ほどのSELECTの確認が済んだ場合だけ**、次のブロックを自分で実行してください。

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT pid, pg_terminate_backend(pid) AS terminated FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = 'ap-server-1' AND pid <> pg_backend_pid();"
```{{exec}}

`pg_terminate_backend` は指定したDBプロセスに終了を要求します。未確定の処理は取り消されます。返された `terminated` を記録し、続いて接続と業務の状態を確認します。

### 3. 接続数と業務ログを確認する

終了操作の時刻を控え、次を実行します。

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT count(*) AS ap1_connections FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = 'ap-server-1';"
/root/lab/scripts/show-connections.sh
docker logs --since 1m ap-server-2 2>&1 | tail -n 20
```{{exec}}

AP1接続数が0本であること、接続一覧にAP2の接続が見えること、操作後の新しい業務ログを確認します。AP2は要求ごとに接続を作成・終了するので、本数が一定である必要はありません。

### 4. DBに記録された業務成功を確認する

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT count(*) AS recent_ap2_success FROM job_history WHERE ap_name = 'ap-server-2' AND status = 'success' AND finished_at > now() - interval '2 minutes';"
```{{exec}}

直近のAP2成功件数が1件以上で、新しい `job SUCCESS:` のログがあることを確認します。操作前の履歴も含み得るため、操作後の時刻・要求IDのログと照合してください。すぐに新しい成功が見えなければ10〜30秒ほど待ち、手順3・4を再実行します。成功を確認できないまま完了と判断しないでください。

</details>

<details>
<summary>判断と技術的な解説：結果を考えてから開く</summary>

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
