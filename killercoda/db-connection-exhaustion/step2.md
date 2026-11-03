Step 1で見つけた接続エラーを、DB側の情報と照合します。ここでは**調査だけ**を行い、接続の終了や設定変更はしません。

**学習目標：PostgreSQLの接続上限と接続の内訳を調べ、気になる接続を特定する。**

## 1. エラーと接続上限を照合する

```bash
cd /root/lab
docker logs ap-server-2 2>&1 | grep -F 'DB connection failed' | tail -n 5
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SHOW max_connections;"
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SHOW superuser_reserved_connections;"
```{{exec}}

- `max_connections`：DB全体の接続上限。
- `superuser_reserved_connections`：管理者用に確保する接続枠。通常の業務ユーザーはこの枠を使えません。
- `postgres`：この演習で調査に使う管理用ユーザーです。`-c`でSQLを実行し、結果表示後にターミナルへ戻ります。

現在のクライアント接続数も調べます。

```bash
docker exec db-server psql -X -P pager=off -U postgres -d appdb -c "SELECT count(*) AS client_connections FROM pg_stat_activity WHERE backend_type = 'client backend';"
```{{exec}}

`pg_stat_activity`は接続や処理の状態を調べるビューです。ここではDB内部のプロセスを除き、クライアント接続だけを数えています。調査用psql自身の接続も含まれるため、一般ユーザーの利用可能枠と単純には一致しません。

## 2. 接続元と状態を分類する

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

## 出力から考えること

- エラーの内容と、上限・予約枠・現在の接続数はどう関係していますか。
- Step 1で確認したAPの状態と、接続元別の件数に食い違いはありませんか。

<details>
<summary>ヒント1：接続元を一つずつ照合する</summary>

接続数が多い行の `application_name` を、Step 1のコンテナ状態と比較してください。業務を実行できないAPに紐づく接続がないか探します。

</details>

<details>
<summary>ヒント2：停止と切断通知は別の出来事</summary>

通信断を伴ってAPが停止すると、DBへ正常な切断通知が届かず、DB側に接続が残る場合があります。この演習では、停止したAP1の接続が残り、AP2が使える接続枠を圧迫していないかを確認してください。

</details>

## CHECK前の確認

- 接続上限と予約枠の違いを説明できる。
- 停止したAPとDB接続の関係を、実際の出力から確認した。
- まだ接続を終了していない。

調査した内容を整理してからCHECKを押してください。
