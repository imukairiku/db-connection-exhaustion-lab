Step 2で特定した問題を解消し、業務を回復させます。正常に稼働しているAP2や管理用接続への影響を抑えるには、どの復旧方針が適切でしょうか。

**操作の目的：復旧対象を限定し、操作後の接続数と新しい業務成功を根拠に復旧を判断する。**

**安全上の注意：必ずSELECTで対象を確認してから終了してください。** 正常なAP2・管理用接続を終了しないこと、固定PIDや全接続の一括終了を使わないことを守ります。本演習ではDB全体を再起動しません。対象が不明なら、終了せず模範解答の確認手順を読んでください。

<details>
<summary>調査・操作のヒント1：対象と影響範囲を決める</summary>

`pg_stat_activity` を `SELECT` し、`WHERE` で対象を絞る方法を考えます。`pg_terminate_backend` は指定したDBプロセスへ接続終了を要求する関数です。終了対象と、残すべき接続を先に区別してください。

</details>

<details>
<summary>調査・操作のヒント2：確認と操作に同じ条件を使う</summary>

接続の種類・アプリ名・管理接続自身の除外を条件にします。確認用SELECTの出力を見てから、終了用SQLでも同じ条件で選び直してください。終了要求の成功と業務回復は別なので、接続数と新しい業務記録を確認します。

</details>

<details>
<summary>模範解答：実行コマンド・SQL（自分で考えてから開く）</summary>

以下を上から順に実行します。開閉だけでは実行されません。出力を確認し、次の操作が安全か判断してから各コードの実行ボタンを押してください。考察問題のヒントと答えは、各問の欄で個別に確認できます。

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

## 考察問題

各問を自分で考え、必要な問の欄だけ開いてください。根拠は自分のログ・SQL出力と照合し、未観測の結果を確認済みと扱わないでください。

### 問1：なぜDB全体を再起動せず、対象の接続だけを終了するのでしょうか。影響範囲を説明してください。

<details>
<summary>ヒントを見る（問1）</summary>

確認用SELECTと終了用SQLの `WHERE` を比べ、対象に含まれる接続・含まれない接続を整理してください。

</details>

<details>
<summary>答えを見る（問1：自分で考えてから開く）</summary>

**結論：DB全体の再起動は正常な接続にも影響するため、対象を限定した接続終了を選びます。**

**根拠：** 確認と終了のSQLは `backend_type = 'client backend'`、`application_name = 'ap-server-1'`、`pid <> pg_backend_pid()` という共通条件を使っています。SELECT出力の接続元・状態も確認します。

**技術的な解説：** `WHERE` によりAP2は対象から除外され、管理接続自身も明示的に除外されます。DB再起動は処理中の正常な接続も切るため、影響範囲が異なります。実運用ではアプリ名だけを信用せず、接続元IPやユーザーも照合して対象を決めてください。

</details>

### 問2：今回の復旧が成功したと判断できる根拠は何ですか。操作結果と業務結果を区別してください。

<details>
<summary>ヒントを見る（問2）</summary>

`terminated` の値、`ap1_connections`、操作後の業務ログ・履歴は、それぞれ何を示すか考えてください。

</details>

<details>
<summary>答えを見る（問2：自分で考えてから開く）</summary>

**結論：AP1由来接続が0本になり、AP2の新しい業務が成功していれば、今回の復旧を成功と判断できます。**

**根拠：** `ap1_connections = 0`、操作後の新しい `job SUCCESS:`、`job_history` の直近 `success` が1件以上という条件を照合します。これは確認すべき条件であり、観測済みの出力例ではありません。

**技術的な解説：** `terminated = t` は終了要求の送信成功で、業務のCOMMITの証拠ではありません。履歴には操作前の成功も入り得るので時刻と要求IDを確認します。AP2の接続数は変動します。接続一覧だけでは一度も正常接続を切っていない証明にはならず、実行条件と前後の出力も必要です。

</details>

### 問3：今回の操作だけで再発を防げるでしょうか。変更したものと、変更していないものを考えてください。

<details>
<summary>ヒントを見る（問3）</summary>

実行したSQLは現在の接続に作用するものか、今後の検知条件を変えるものかを振り返ってください。

</details>

<details>
<summary>答えを見る（問3：自分で考えてから開く）</summary>

**結論：今回の操作だけでは再発を防げず、暫定復旧に当たります。**

**根拠：** 実行したのは `pg_terminate_backend` による現在の接続の終了で、検知条件やタイムアウト設定を変更する操作ではありません。

**技術的な解説：** 現在の残留接続を解消しても、次の障害で接続が残る仕組みは変わりません。再発時の自動解放やタイムアウト設計は別の対策として検討します。今回は業務回復を優先した対応であり、恒久対策とは区別します。

</details>

## CHECK前の確認

- 対象をSELECTで確認してから終了した。
- AP1接続が0本になった。
- AP2の新しい業務成功を確認した。
- 暫定復旧と恒久対策の違いを説明できる。

CHECKはAP1接続0本と最近のAP2業務成功を判定します。操作の影響範囲や、成功が操作後の新しいものであることも自分で確認してください。既存CHECKはDB再起動の有無や正常接続の保持までは判定しないため、CHECK成功だけで操作方法の正しさを保証するものではありません。

CHECK後はStep 4へ進み、残留接続を自動解放する恒久対策と再試験に取り組みます。
