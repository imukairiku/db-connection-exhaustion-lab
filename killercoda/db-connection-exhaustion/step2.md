# Step 2: DB接続数調査と残留接続特定

`ap-server-2` はDB接続に失敗していました。DB側から原因を調査します。

管理用の接続には `postgres` ユーザーを使用します(演習専用の管理アカウントです)。

```````````````````````````bash
docker exec -it db-server psql -U postgres -d appdb
``````````````````````````{{exec}}

## 問2: 接続エラーの切り分け

PostgreSQL自体は稼働しているのに接続できないのはなぜでしょうか。
接続数の上限と現在値を確認してください。

`````````````````````````sql
SHOW max_connections;
````````````````````````{{copy}}

```````````````````````sql
SELECT count(*)
FROM pg_stat_activity;
``````````````````````{{copy}}

<details>
<summary>ヒント(数値の見方)</summary>

- `max_connections = 20` に対し、接続数が上限付近になっているはずです。
- `pg_stat_activity` の件数にはPostgreSQL内部のバックグラウンドプロセスも含まれます。
  クライアント接続だけを数える場合は `WHERE backend_type = 'client backend'` を付けます。
- なお、あなたが今 `postgres` ユーザーで接続できているのは、superuser用の予約枠
  (`superuser_reserved_connections = 3`)があるためです。一般ユーザー(AP)は
  実質 17 本で枯渇します。

</details>

## 問3: 残留接続の特定

どのAPが接続を使っているのかを調べます。

`````````````````````sql
SELECT
    application_name,
    client_addr,
    state,
    count(*)
FROM pg_stat_activity
GROUP BY application_name, client_addr, state
ORDER BY application_name;
````````````````````{{copy}}

## 確認ポイント

- 接続数の内訳で気になる点はありませんか?
- Step 1 で確認したとおり `ap-server-1` は**停止済み**です。
  それにもかかわらず `ap-server-1` の接続が残っているのはなぜでしょうか?

<details>
<summary>ヒント(なぜ残るのか)</summary>

`ap-server-1` はネットワーク断を伴う形で異常停止しました。
TCPは、相手が「黙って消えた」場合にそれを即座に検知できません。
PostgreSQLサーバ側は切断通知(FIN/RST)を受け取っていないため、
接続が生きていると判断し続け、接続スロットを占有し続けます。

この「残留接続」が上限を圧迫し、新現用系 `ap-server-2` の新規接続が
`remaining connection slots are reserved ...` で失敗しています。

</details>

## 次のステップへ進む条件

- 接続数が上限付近であること、停止済み `ap-server-1` 由来の接続が残留していることを確認できていること

確認できたら CHECK を押してください(psqlは `\q` で抜けられますが、接続したままでも構いません)。
