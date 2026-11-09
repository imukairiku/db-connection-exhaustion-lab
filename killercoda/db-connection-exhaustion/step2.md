Step 1では、AP2への切替と業務の成否を分けて確認しました。なぜ業務が正常に継続できないのでしょうか。APのエラーを手掛かりに、DB側の情報と照合してください。

**調査の目的：エラーログとDBの設定・接続状況を調べ、原因とその根拠を説明する。**

## 考える問題

1. APのエラーは何を示していますか。DB側の設定と照合して説明してください。
2. 現在どの接続元が、どの状態で、何本の接続を使用していますか。APの稼働状態との関係を調べてください。
3. その状況が生じた理由として何が考えられますか。観測した事実と仮説を分けてください。

このStepは調査のみです。接続終了・設定変更は行いません。調査結果を記録してから答え合わせをしてください。

<details>
<summary>ヒント1：APとDBの情報を照合する</summary>

APのエラーログとDB側の情報を照合し、どの種類の情報が根拠になるか考えてください。

</details>

<details>
<summary>ヒント2：接続状況を調べる手掛かり</summary>

PostgreSQLの `pg_stat_activity` は接続や処理の状態を調べるビューです。接続元・状態・件数を調べ、APの稼働状態と比較します。`WHERE` で対象を絞り、`GROUP BY` と集計で内訳を整理できます。どの接続が問題かは、自分の出力から判断してください。

</details>

<details>
<summary>模範解答：実行コマンド・SQL（自分で考えてから開く）</summary>

以下を上から順に実行します。開閉だけでは実行されません。出力を確認し、次の操作が安全か判断してから各コードの実行ボタンを押してください。「判断と技術的な解説」は別に開くまで表示されません。

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

<details>
<summary>判断と技術的な解説：結果を考えてから開く</summary>

`active`はSQL実行中、`idle`はトランザクション外で要求を待つ状態、`idle in transaction`はトランザクションを開いたまま次の要求を待つ状態です。状態名だけでは異常と決めず、接続元とAPの状態を照合します。

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

- 設定・接続状況・APの状態を照合して調査した。
- 3問に、ログとSQLの出力を根拠として答えられる。
- 接続終了や設定変更は行っていない。

CHECKはDB接続の内訳・件数を判定し、既に復旧済みの場合は最近の業務成功も確認します。考察内容は採点しません。既に復旧済みでも通過できる既存仕様のため、成功だけを調査結果の代わりにしないでください。確認できたらStep 3へ進み、影響範囲を限定した復旧方針を考えます。
