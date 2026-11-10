Step 1では、AP2への切替と業務の成否を分けて確認しました。なぜ業務が正常に継続できないのでしょうか。APのエラーを手掛かりに、DB側の情報と照合してください。

**調査の目的：エラーログとDBの設定・接続状況を調べ、原因とその根拠を説明する。**

このStepは調査のみです。接続終了・設定変更は行いません。調査結果を記録してから答え合わせをしてください。

<details>
<summary>調査・操作のヒント1：APとDBの情報を照合する</summary>

APのエラーログとDB側の情報を照合し、どの種類の情報が根拠になるか考えてください。

</details>

<details>
<summary>調査・操作のヒント2：接続状況を調べる手掛かり</summary>

PostgreSQLの `pg_stat_activity` は接続や処理の状態を調べるビューです。接続元・状態・件数を調べ、APの稼働状態と比較します。`WHERE` で対象を絞り、`GROUP BY` と集計で内訳を整理できます。どの接続が問題かは、自分の出力から判断してください。

</details>

<details>
<summary>模範解答：実行コマンド・SQL（自分で考えてから開く）</summary>

以下を上から順に実行します。開閉だけでは実行されません。出力を確認し、次の操作が安全か判断してから各コードの実行ボタンを押してください。考察問題のヒントと答えは、各問の欄で個別に確認できます。

### 1. APのエラーを再確認する

```bash
cd /root/lab
docker logs ap-server-2 2>&1 | grep -F 'DB connection failed' | tail -n 5
```{{exec}}

`grep -F` は指定文字列を含む行を探し、`tail -n 5` は最後の5行を表示します。`detail=` の内容を記録してください。

### 2. 接続上限と予約枠を確認する

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SHOW max_connections;"
```{{exec}}

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SHOW superuser_reserved_connections;"
```{{exec}}

`max_connections` はDB全体の接続上限、`superuser_reserved_connections` はスーパーユーザー向けの予約枠です。`postgres` はこの演習の調査用管理ユーザーです。`-X` はpsqlの起動設定ファイルを読み込まず、`-P pager=off` はページ送りを無効にし、`-c` はSQL実行後に終了します。

### 3. 現在のクライアント接続数を確認する

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT count(*) AS client_connections FROM pg_stat_activity WHERE backend_type = 'client backend';"
```{{exec}}

`pg_stat_activity` は接続や処理の状態を調べるビューです。`backend_type` でDB内部のプロセスを除きます。調査用psql自身も数に含まれ、観測時点で件数は変動します。

### 4. 接続元・状態ごとの内訳を確認する

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT application_name, client_addr, state, count(*) AS connections FROM pg_stat_activity WHERE backend_type = 'client backend' GROUP BY application_name, client_addr, state ORDER BY application_name, state;"
```{{exec}}

| 列 | 確認する情報 |
|---|---|
| `application_name` | アプリが設定した接続名 |
| `client_addr` | 接続元IP。ローカルソケット接続では空欄になる |
| `state` | 接続や処理の現在の状態 |
| `connections` | 同じ接続元・状態に分類された件数 |

`GROUP BY` で分類し、`count(*)` で件数を集計しています。特定の接続元を先に絞らず、APの稼働状態・エラーと内訳を照合してください。このStepでは接続終了や設定変更は行いません。

</details>

## 考察問題

各問を自分で考え、必要な問の欄だけ開いてください。根拠は自分のログ・SQL出力と照合し、未観測の結果を確認済みと扱わないでください。

### 問1：なぜAP2はDB接続に失敗しているのでしょうか。エラーとDBの設定を照合してください。

<details>
<summary>ヒントを見る（問1）</summary>

APエラーの詳細と、上限・予約枠の `SHOW` 結果を比べてください。この問では接続元を特定する前に、失敗の種類を考えます。

</details>

<details>
<summary>答えを見る（問1：自分で考えてから開く）</summary>

**結論：本演習の想定状態では、一般ユーザーが利用できる接続枠が不足しています。**

**根拠：** 自分のAPログに `FATAL: remaining connection slots are reserved for roles with the SUPERUSER attribute` があるか確認します。`SHOW` で確認する本演習の設定は `max_connections = 20`、`superuser_reserved_connections = 3` です。別のエラーが出た場合は、その内容も記録してください。

**技術的な解説：** 他の予約枠がなければ、一般ユーザー向けは最大20−3＝17本で、業務ユーザー間で共用します。管理ユーザーは予約枠を使えるため、管理用psqlが接続できても業務接続が成功するとは限りません。現在の件数は調査用接続も含み、エラー発生時から変動します。この問では不足の種類を判断し、どの接続が占有しているかは別途調べます。

</details>

### 問2：どの接続が問題と考えられますか。接続元・状態・件数とAPの稼働状態を比較してください。

<details>
<summary>ヒントを見る（問2）</summary>

`application_name`・`client_addr`・`state`・集計件数を確認し、APの稼働状態と比較してください。状態名だけで異常とは決めないようにしましょう。

</details>

<details>
<summary>答えを見る（問2：自分で考えてから開く）</summary>

**結論：停止したAP1由来の接続が残り、接続枠を圧迫しています。**

**根拠：** Step 1でAP1が `Paused` である一方、集計SQLに `application_name = ap-server-1` の行が残っていることです。`client_addr` を接続元と照合し、`state` と `connections` を読み取ります。本演習ではAP1由来の `idle in transaction` が残ることを確認していますが、本数は自分の出力から記録してください。

**技術的な解説：** `active` はSQL実行中、`idle` はトランザクション外で要求を待つ状態、`idle in transaction` はトランザクションを開いたまま次の要求を待つ状態です。状態名だけで異常とは決めず、停止した接続元との食い違いを根拠にします。正常なAPや管理用接続まで問題と扱わないでください。この記録だけで、接続が残った仕組みまでは断定できません。

</details>

### 問3：問2で特定した状態が生じた理由は何でしょうか。観測した事実と背景の仮説を分けてください。

<details>
<summary>ヒントを見る（問3）</summary>

APの処理停止と、DBが接続終了を認識することは同じでしょうか。観測結果だけで断定できることと、障害発生時の条件が必要なことを分けてください。

</details>

<details>
<summary>答えを見る（問3：自分で考えてから開く）</summary>

**結論：本演習では、AP1とDB間の通信を遮断してからAP1をpauseしたため、DBが接続終了を直ちに検知できず接続が残りました。**

**根拠：** 観測上は、AP1の `Paused` 状態と、DB側でその接続が残るSQL出力を照合できます。通信遮断→pauseの順序は本演習の障害注入処理の背景条件です。SQL出力だけから通信遮断まで分かるわけではありません。

**技術的な解説：** 正常な切断通知が届かず、DB側の切断検知やタイムアウトがまだ働いていない間、接続が残る場合があります。今回は「通信遮断・pause→接続残留→枠の圧迫→新規接続失敗」という関係です。実運用では別の障害条件もあり得るため、今回の背景を一般化しないでください。

</details>

<details>
<summary>操作を間違えた・最初からやり直したい場合</summary>

Step 1開始時と同等の障害状態を作り直します。**現在の接続・設定・演習状態が変わる操作です。** 必要な調査結果は実行前に手元へ控えてください。通常の復旧操作ではなく、演習を最初からやり直すための操作です。

開くだけでは実行されません。やり直すと決めた場合のみ、次のコードを明示的に実行してください。

```bash
cd /root/lab
/root/lab/scripts/create-failed-state.sh
```{{exec}}

既存の業務接続を整理し、APの役割を初期化した後、障害を再注入します。Step 4のタイムアウト設定も初期状態へ戻し、以前の再試験完了マーカーを破棄します。調査中の接続・ログの状況やCHECKの判定対象も変わります。Step 4の設定適用と再試験は、後で改めて実施してください。

正常終了後は、AP1がpause、AP2がACTIVE、DBが稼働し、停止したAP由来の接続とAP2の接続エラーを観察する開始状態に戻ります。完了前やエラー時は復元成功と判断しないでください。

**実行後は画面のStep 1へ戻り、調査し直してください。** このコマンドは画面のStep位置を自動で戻しません。

</details>

## CHECK前の確認

- 設定・接続状況・APの状態を照合して調査した。
- 3問に、ログとSQLの出力を根拠として答えられる。
- 接続終了や設定変更は行っていない。

CHECKはDB接続の内訳・件数を判定し、既に復旧済みの場合は最近の業務成功も確認します。考察内容は採点しません。既に復旧済みでも通過できる既存仕様のため、成功だけを調査結果の代わりにしないでください。確認できたらStep 3へ進み、影響範囲を限定した復旧方針を考えます。
