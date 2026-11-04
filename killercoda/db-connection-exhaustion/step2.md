Step 1ではAP2の昇格を確認した一方、`DB connection failed:` が記録されていました。なぜDBへ接続できないのでしょうか。ログとPostgreSQL側の情報を照合します。ここでは**調査だけ**を行い、接続の終了や設定変更はしません。

**学習目標：接続上限と実際の接続状況を調べ、どの接続がエラーにつながっているかを、ログとSQLの出力を根拠に説明する。**

## 1. エラーログを確認する

```bash
cd /root/lab
docker logs ap-server-2 2>&1 | grep -F 'DB connection failed' | tail -n 5
```{{exec}}

`detail=` の説明を読み、DBサーバの停止・通信障害・接続枠不足など、どの可能性を示しているか考えてください。「接続失敗」という言葉だけで原因を決めつけないようにしましょう。

## 2. PostgreSQLの接続上限を確認する

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SHOW max_connections;"
```{{exec}}

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SHOW superuser_reserved_connections;"
```{{exec}}

- `max_connections`：DB全体の接続上限。
- `superuser_reserved_connections`：管理者用に確保する接続枠。通常の業務ユーザーはこの枠を使えません。
- `postgres`：この演習で調査に使う管理用ユーザーです。`-c`でSQLを実行し、結果表示後にターミナルへ戻ります。

## 3. 現在の接続数を見る

上限と比べるため、現在のクライアント接続数を調べます。

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT count(*) AS client_connections FROM pg_stat_activity WHERE backend_type = 'client backend';"
```{{exec}}

`pg_stat_activity`は接続や処理の状態を調べるビューです。ここではDB内部のプロセスを除き、クライアント接続だけを数えています。調査用psql自身の接続も含まれるため、一般ユーザーの利用可能枠と単純には一致しません。

## 4. 接続元と状態を分類する

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT application_name, client_addr, state, count(*) AS connections FROM pg_stat_activity WHERE backend_type = 'client backend' GROUP BY application_name, client_addr, state ORDER BY application_name, state;"
```{{exec}}

| 列 | 読み方 |
|---|---|
| `application_name` | 接続元アプリが設定した名前。この演習ではAPを識別する手掛かり |
| `client_addr` | 接続元IPアドレス。DB内のローカル接続では空欄になることもある |
| `state` | 接続が現在どのような状態か |
| `connections` | 同じ接続元・状態に分類された件数（`count(*)`） |

`active`はSQL実行中、`idle`はトランザクション外で次の要求を待つ状態です。`idle in transaction`は、トランザクション（まとめて確定・取り消しを行う処理単位）を開いたまま次の要求を待つ状態です。待機状態だけで異常と決めず、APの稼働状態と比べてください。

## 5. 出力から考えること

- **問1：なぜAP2はDB接続に失敗しているのでしょうか？** エラーログ・最大接続数・予約接続枠を根拠に説明してください。
- **問2：どのサーバの接続が問題となっているのでしょうか？** `application_name`・`client_addr`・`state`・接続数を根拠に考えてください。
- **問3：なぜ問題の接続がDB側に残っているのでしょうか？** Step 1で確認したAP1の状態と、DB側の接続状態を関連付けて考えてください。

<details>
<summary>ヒント1：接続元を一つずつ照合する</summary>

接続数が多い行の `application_name` を、Step 1のコンテナ状態と比較してください。業務を実行できないAPに紐づく接続がないか探します。

</details>

<details>
<summary>ヒント2：停止と切断通知は別の出来事</summary>

APの処理が止まることと、DB側が接続終了を検知することは別です。DBは何を手掛かりに終了を知るのでしょうか。待機状態という理由だけで、正常なAPや管理用の接続まで異常と判断しないようにしましょう。

</details>

<details>
<summary>模範解答：自分で3問を考えてから開く</summary>

以下は本演習の障害状態についての模範解答です。接続数や状態は観測時点で変わるため、自分の出力と照合してください。ログやSQLで確認できない内容を、観測済みの事実として扱わないでください。

### 問1：AP2が接続に失敗する理由

**答え：PostgreSQLの一般ユーザーが使用できる接続枠が不足している。**

根拠となるログは、AP2の `DB connection failed:` に続く、次のエラーです。自分のログにこの文言があるか確認してください。

> `FATAL: remaining connection slots are reserved for roles with the SUPERUSER attribute`

設定ファイルで確認した本演習の設定は `max_connections = 20`、`superuser_reserved_connections = 3` です。先ほどの `SHOW` の結果と照合します。他の予約枠がない場合、一般ユーザーが利用できる枠は最大 **20 − 3 = 17本**で、AP1とAP2などが共用します。AP2専用の17本ではありません。

管理用ユーザーは予約枠を利用できるため、管理用psqlが接続できても業務ユーザーが接続できるとは限りません。また、現在の接続数はエラー発生時から変動し、調査用psqlも含みます。件数だけでなく、エラーの内容と接続の内訳を合わせて判断します。

### 問2：接続枠を圧迫している接続

**答え：障害が発生したAP1由来の残留接続が、接続枠を圧迫している。**

根拠は、Step 1でAP1が `Paused` である一方、集計SQLに `application_name = ap-server-1` の行が残っていることです。その行の `client_addr` をAP1の接続元として確認し、`state` と `connections` も照合してください。本演習ではAP1由来の `idle in transaction` 接続が残ることを確認しています。実際の本数は自分の出力から読み取ります。

AP2や調査用psqlの接続もあるため、すべての接続が問題なのではありません。停止したAPに対応する接続が残っている点が重要です。`idle in transaction` という状態だけで、すべて異常とは判断しません。

### 問3：接続が残留した背景

**答え：本演習では、AP1とDB間の通信が遮断された状態でAP1がpauseされ、DBが接続終了を直ちに検知できなかったため、接続が残留している。**

観測上の根拠は、AP1が `Paused` なのにDB側にAP1の接続が残っていることです。通信遮断後にpauseする順序は、本演習の障害注入処理で確認できる背景条件です。SQLの出力だけから通信遮断まで断定できるわけではありません。

DBへ正常な切断通知が届かず、DB側の切断検知やタイムアウトもまだ働いていない間は、接続が残る場合があります。`idle in transaction` はトランザクションを開いたまま次の要求を待っている状態で、業務が正常に進んでいるという意味ではありません。これは今回の演習での原因であり、実際の業務システムでは別の障害条件も調査する必要があります。

### まとめ

**AP1の通信遮断・停止 → DB側にAP1由来の接続が残留 → 接続枠を圧迫 → AP2からの新規DB接続が失敗 → 業務処理が正常に継続できない**、という関係です。

「DB接続枯渇」は障害として現れている現象、「AP1由来の残留接続」は枠を圧迫する原因、「通信遮断とAP1の一時停止」は今回その接続が残った背景として区別してください。

</details>

## CHECK前の確認

- 接続上限と予約枠を確認した。
- AP1とAP2の接続数・状態を確認した。
- 3つの問いに、ログとSQLの出力を根拠として答えられる。
- 接続の終了や設定変更は行っていない。

調査した内容を整理してからCHECKを押してください。CHECKは環境の状態を判定するもので、考察内容を採点するものではありません。既に復旧済みでも通過できる既存仕様のため、CHECKの成功だけを調査結果の代わりにしないでください。

CHECK後はStep 3へ進み、調査で特定した残留接続を限定的に終了して暫定復旧します。このStepではまだ終了操作を行いません。
