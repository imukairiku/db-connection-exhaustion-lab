# Step 4: 恒久対策(TCP Keepalive)と再試験

暫定復旧はできましたが、同じ障害が起きれば再発します。恒久対策を考えましょう。

## 問6: 恒久対策の検討と適用

**考えてみてください**: 今回の根本原因は「サーバ側がクライアントの消滅を検知できず、接続が残留したこと」です。どのような対策が考えられますか?

<details>
<summary>考察(開く前に自分の答えを持ってください)</summary>

- `max_connections` を増やす → **根本対策になりません**。残留接続は増え続けるため、
  上限をいくら上げてもいずれ枯渇します(検知・解放の仕組みがないことが本質)。
- **TCP Keepalive の見直し** → サーバ側から定期的に生存確認パケットを送り、
  応答がなければ接続を自動切断する仕組みです。今回の恒久対策として採用します。
- 実運用ではこのほか、接続プーラー(PgBouncer等)、`idle_session_timeout`、
  AP側のタイムアウト設計などを組み合わせる多層防御が一般的です。

</details>

用意済みのスクリプトで以下を適用します。

`````````text
tcp_keepalives_idle     = 20   (無通信20秒でプローブ開始)
tcp_keepalives_interval = 5    (5秒間隔で再送)
tcp_keepalives_count    = 3    (3回無応答で切断)
→ 検知目安: 20 + 5×3 = 約35秒
`````````

`````````bash
/root/apply-keepalive-setting.sh
````````{{exec}}

設定値を確認します。

```````bash
docker exec -it db-server psql -U postgres -c "SELECT name, setting FROM pg_settings WHERE name LIKE 'tcp_keepalives%';"
``````{{exec}}

> **注意**: idle=20秒は演習で効果を短時間に観察するための値です。
> 本番環境では誤検知やNW負荷を考慮した十分に長い値を設計してください。

## 問7: 再試験

対策の効果を確認するため、同じ障害を再現します。以下のスクリプトが、
正常化 → 負荷開始 → 通信断+pause → 切替 → 接続数の時系列表示 を自動実行します。

`````bash
/root/retest.sh
````{{exec}}

## 期待する確認結果

対策**前**は残留接続が(2時間以上)解放されませんでしたが、対策**後**は:

```text
  0秒  ap-server-1=10  ap-server-2=2
 10秒  ap-server-1=10  ap-server-2=5
 20秒  ap-server-1=10  ap-server-2=7
 40秒  ap-server-1=0   ap-server-2=12
```

のように、**約35〜40秒で残留接続が自動解放**され、`ap-server-2` の業務が
人手の介入なしに回復します(数値は実測のため多少前後します)。

## 次のステップへ進む条件

- Keepalive設定が適用済みであること
- 再試験が成功していること(残留接続の自動解放と業務回復)

確認できたら CHECK を押してください。
