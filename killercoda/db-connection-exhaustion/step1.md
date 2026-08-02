# Step 1: 状況確認とAP切替確認

まず、各サーバの稼働状態と、AP切替が行われたかを確認します。

## 問1

以下を確認してください。

1. 各コンテナの稼働状態
2. `ap-server-2` が現用系へ昇格しているか
3. `ap-server-2` の業務処理は正常か

## 実行するコマンド

作業ディレクトリは `/root/lab` です。

```````````````````````````````bash
cd /root/lab
docker compose ps
``````````````````````````````{{exec}}

`````````````````````````````bash
docker logs --tail 20 ap-server-2
````````````````````````````{{exec}}

## 確認ポイント

- `ap-server-1` はどのような状態ですか?
- `ap-server-2` のログに `PROMOTED to ACTIVE` はありますか?(=切替は成功しているか)
- 切替後の `ap-server-2` の業務処理は成功していますか? 失敗している場合、どのようなエラーですか?

<details>
<summary>ヒント1(状態の見方)</summary>

`docker compose ps` の STATUS 列に注目してください。
`ap-server-1` が `Paused` になっているはずです(現用系の異常を模擬)。

</details>

<details>
<summary>ヒント2(ログの読み方)</summary>

`ap-server-2` のログには次の2種類が混在しています。

- `PROMOTED to ACTIVE` : 切替成功の証跡
- `[ERROR] DB connection failed: ... FATAL: remaining connection slots are reserved ...` : DB接続の失敗

つまり「**AP切替は成功したが、DB接続に失敗して業務継続できていない**」状態です。
なぜDBに接続できないのか、Step 2 で調査します。

</details>

## 次のステップへ進む条件

- `ap-server-1` が停止(pause)状態、`ap-server-2` と `db-server` が稼働中であることを確認できていること

確認できたら CHECK を押してください。
