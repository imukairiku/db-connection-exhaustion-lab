# Step 4: 恒久対策と再試験

暫定復旧はできましたが、同じ障害が起きれば再発します。恒久対策を考えましょう。

## 問6: 恒久対策の検討と適用

**考えてみてください**: 今回の根本原因は何だったでしょうか?
Step 2 で残留接続の状態(`state`列)を確認したことを思い出してください。

<details>
<summary>ヒント: 残留接続の状態は?</summary>

Step 2 で確認した接続一覧を思い出してください。ap-server-1 由来の接続は
`idle in transaction` の状態でした。つまり:

- クライアント(ap-server-1)は処理途中で消えた
- しかしDBサーバから見ると「トランザクション中で待機している」状態
- サーバは切断通知を受けていないため、この接続を保持し続けた

対策の方向性は「**この idle in transaction 状態が続いた接続を、
サーバ側から強制的に切断する仕組み**」を導入することです。

</details>

<details>
<summary>考察: どの対策が有効か</summary>

- **max_connections を増やす** → **根本対策になりません**。残留接続は増え続けるため、
  上限をいくら上げてもいずれ枯渇します。
- **TCP Keepalive** → サイレント切断の検知には有効。ただしOS/カーネル依存で
  環境によっては期待通りに動作しないケースがあります。
- **`idle_in_transaction_session_timeout`** → **今回の残留接続に最適**。
  トランザクション中に一定時間何もない接続をPostgreSQL自身が強制切断します。
  カーネル依存がなく、環境問わず確実に動作します。
- **接続プーラー(PgBouncer 等)や AP側のタイムアウト設計**も、
  実運用では組み合わせて使用します(多層防御)。

本演習では **`idle_in_transaction_session_timeout`** を採用します。

</details>

用意済みのスクリプトで以下を適用します。

`````````text
idle_in_transaction_session_timeout = 30s
→ トランザクション中に30秒何もない接続を強制切断
→ 検知目安: 約30秒
`````````

`````````bash
/root/lab/scripts/apply-keepalive-setting.sh
````````{{exec}}

> **補足**: スクリプト名は歴史的経緯で `keepalive` を含んでいますが、
> 実際に適用するのは `idle_in_transaction_session_timeout` です。

設定値を確認します。

```````bash
docker exec -it db-server psql -U postgres -c "SHOW idle_in_transaction_session_timeout;"
``````{{exec}}

> **注意**: `30s` は演習で効果を短時間に観察するための値です。
> 本番環境では、業務トランザクションの最長実行時間を踏まえて
> 十分に長い値を設計してください。短すぎると正常なトランザクションが
> 途中で切断される事故につながります。

## 問7: 再試験

対策の効果を確認するため、同じ障害を再現します。以下のスクリプトが、
正常化 → 負荷開始 → 通信断+pause → 切替 → 接続数の時系列表示 を自動実行します。

`````bash
/root/lab/scripts/retest.sh
````{{exec}}

## 期待する確認結果

対策**前**は残留接続がずっと解放されませんでしたが、対策**後**は:

```text
  0秒  ap-server-1=10  ap-server-2=2
 10秒  ap-server-1=10  ap-server-2=5
 20秒  ap-server-1=10  ap-server-2=7
 30秒  ap-server-1=0   ap-server-2=12
```

のように、**約30秒で残留接続が自動解放**され、`ap-server-2` の業務が
人手の介入なしに回復します(数値は実測のため多少前後します)。

## 次のステップへ進む条件

- `idle_in_transaction_session_timeout` が `30s` に設定されていること
- 再試験が成功していること(残留接続の自動解放と業務回復)

確認できたら CHECK を押してください。
````

---

## 修正4:killercoda/db-connection-exhaustion/verify-step4.sh

````bash
cloudshell edit killercoda/db-connection-exhaustion/verify-step4.sh
````

全選択→削除→以下を貼り付け→保存:

````bash
#!/usr/bin/env bash
# =============================================================================
# Step4 検証
# =============================================================================
set -Eeuo pipefail

fail() { echo "[VERIFY NG] $*" >&2; exit 1; }

psql_q() {
  docker exec -i db-server psql -U postgres -d appdb -Atq -c "$1" 2>/dev/null
}

RETEST_MARKER="/tmp/lab-state/retest-done"

timeout_val="$(psql_q 'SHOW idle_in_transaction_session_timeout;')" || fail "DBへ接続できません"

[ "${timeout_val}" = "30s" ] \
  || fail "idle_in_transaction_session_timeout が適用されていません (現在値: ${timeout_val})。/root/lab/scripts/apply-keepalive-setting.sh を実行してください"

[ -f "${RETEST_MARKER}" ] \
  || fail "再試験が完了していません。/root/lab/scripts/retest.sh を実行してください"

leftover="$(psql_q "SELECT count(*) FROM pg_stat_activity
                    WHERE backend_type='client backend'
                      AND application_name='ap-server-1';")"
[ "${leftover}" -eq 0 ] \
  || fail "ap-server-1 由来の接続が ${leftover} 本残っています(再試験の完了を待ってください)"

ok="$(psql_q "SELECT count(*) FROM job_history
              WHERE ap_name='ap-server-2'
                AND status='success'
                AND finished_at > now() - interval '3 minutes';")"
if [ "${ok}" -eq 0 ]; then
  docker logs --since 3m ap-server-2 2>&1 | grep -q "job SUCCESS" \
    || fail "ap-server-2 の業務成功を確認できません"
fi

echo "[VERIFY OK] Step4: 恒久対策と再試験の完了を確認しました。finish へ進んでください"
exit 0
````

---

## 修正5:killercoda/db-connection-exhaustion/finish.md

````bash
cloudshell edit killercoda/db-connection-exhaustion/finish.md
````

全選択→削除→以下を貼り付け→保存:

````markdown
# 演習完了

お疲れさまでした。本演習では次を体験しました。

## 学んだこと

1. **AP切替成功 ≠ 業務復旧**
   冗長切替が設計どおり動作しても、DB接続枯渇のような共有リソースの問題で
   業務が継続できないことがある。信頼性試験では「切替後に業務が回復すること」
   まで確認する必要がある。
2. **pg_stat_activity による調査**
   `application_name` を業務側で設定しておくことで、接続元の特定が容易になる。
   接続の `state` 列(active / idle / idle in transaction)から状況を読み解ける。
3. **pg_terminate_backend による暫定復旧**
   必ず SELECT で対象を確認してから、同じ WHERE 句で終了する。
4. **`idle_in_transaction_session_timeout` による恒久対策**
   トランザクション中に一定時間何もない接続をPostgreSQL側から強制切断できる。
   カーネル依存がなく、環境を問わず確実に動作する。

## 対策の選択について

今回の残留接続は **`idle in transaction`** 状態でした。これに対する対策の選択肢:

| 対策 | 有効性 | 特徴 |
|---|---|---|
| max_connections を増やす | ❌ | 根本対策にならない |
| TCP Keepalive | △ | サイレント切断には有効だがOS/カーネル依存 |
| **idle_in_transaction_session_timeout** | ◎ | 今回の状態に最適・環境非依存 |
| idle_session_timeout | ○ | idle接続(トランザクション外)には有効 |
| 接続プーラー(PgBouncer 等) | ◎ | 実運用では併用が王道 |
| AP側のタイムアウト設計 | ○ | 多層防御の一部として重要 |

**残留接続の `state` を正しく観察することが対策選択の第一歩**です。

## 実運用への注意

- **max_connections を増やすだけでは根本対策にならない**。残留接続を検知・解放する
  仕組みがなければ、上限をいくら上げてもいずれ枯渇する。
- **本演習の `30s` は演習専用**。本番では業務トランザクションの最長実行時間を
  踏まえて十分に長い値を設計すること。短すぎると正常な処理まで切断される。
- 実運用では多層防御を検討する: 接続プーラー(PgBouncer等)、
  AP側の接続タイムアウト・リトライ設計、監視(接続数のしきい値アラート)。
- 本演習のパスワード・設定値は演習専用であり、本番流用は不可。

## 環境を触ってみたい場合

セッションが残っている間は、以下で正常状態へ戻して自由に再実験できます。

- `/root/lab/scripts/reset-environment.sh` : 正常状態へリセット
- `/root/lab/scripts/inject-failure.sh` : 障害の再投入
- `/root/lab/scripts/show-connections.sh` : 接続状況の表示
````

---

## 修正6:他のスクリプトのsymlink対応(念のため)

`readlink -f` を追加すべきスクリプトが他にもあります。一括修正のsedを回します:

````bash
cd ~/troublebaster/db-connection-exhaustion-lab

# すべての scripts配下のスクリプトに readlink -f を追加
for f in lab/scripts/setup.sh lab/scripts/start-normal-load.sh \
         lab/scripts/inject-failure.sh lab/scripts/clear-failure.sh \
         lab/scripts/create-failed-state.sh lab/scripts/show-connections.sh \
         lab/scripts/reset-environment.sh; do
  sed -i 's|source "\$(cd "\$(dirname "\${BASH_SOURCE\[0\]}")" && pwd)/common.sh"|source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" \&\& pwd)/common.sh"|' "$f"
done

# 確認
grep -l "readlink -f" lab/scripts/*.sh
````

想定出力:

````text
lab/scripts/apply-keepalive-setting.sh
lab/scripts/clear-failure.sh
lab/scripts/create-failed-state.sh
lab/scripts/inject-failure.sh
lab/scripts/reset-environment.sh
lab/scripts/retest.sh
lab/scripts/setup.sh
lab/scripts/show-connections.sh
lab/scripts/start-normal-load.sh
````

9ファイルすべてに `readlink -f` が入っていればOK。

---

## 修正7:docs/environment-differences.md に追記

````bash
cloudshell edit docs/environment-differences.md
````

ファイルの末尾に以下を追記(既存内容の後ろ):

````markdown

## 実測結果と設計変更(2026-08)

Cloud Shell / Killercoda の両方で TCP Keepalive の setsockopt が
効かないことが実測で判明した:

- `postgresql.auto.conf` には `tcp_keepalives_idle = '20'` が書かれる
- しかし `SHOW tcp_keepalives_idle` は常に `0` を返す
- setsockopt(TCP_KEEPIDLE) がコンテナ環境では有効にならないと推測される

このため、恒久対策を **`idle_in_transaction_session_timeout`** へ変更した:

- カーネル依存がない(PostgreSQL 内部のタイマーで動作)
- 今回の残留接続の状態(`idle in transaction`)に対して最適
- Cloud Shell / Killercoda ともに確実に動作
- 教材上の説明も自然(残留接続の `state` を観察してから対策を選ぶ流れ)

`apply-keepalive-setting.sh` のスクリプト名は歴史的経緯でそのまま残している。
````

---

## commit & push

````bash
cd ~/troublebaster/db-connection-exhaustion-lab

# 変更差分の確認
git status
git diff --stat

# コミット
git add -A
git commit -m "Change permanent countermeasure from TCP Keepalive to idle_in_transaction_session_timeout"
git push
````

---

## KillercodaでSync → 再起動 → 検証

1. Killercoda Creator画面で **Sync Now**
2. Git Commit が更新されることを確認
3. シナリオを閉じて再起動
4. 「準備完了」を待つ(3〜5分)
5. 以下を確認:

````bash
# ① 環境完了
tail -20 /var/log/lab-setup.log | tail -5

# ② DROP方式
cat /tmp/lab-state/drop-method

# ③ 恒久対策の適用テスト(★今回の焦点)
docker exec db-server psql -U postgres -c "SHOW idle_in_transaction_session_timeout;"
/root/lab/scripts/apply-keepalive-setting.sh
docker exec db-server psql -U postgres -c "SHOW idle_in_transaction_session_timeout;"
````

**③の最後で `30s` が返ってくれば成功**です。TCP Keepaliveと違って、これは環境非依存の内部タイマーなので確実に動きます。

その後:

````bash
/root/lab/scripts/retest.sh
````

30秒付近で `ap-server-1=0` になるはずです。

---

## まず修正1〜7を実行してください

順に:

1. `apply-keepalive-setting.sh` 全文貼り替え
2. `retest.sh` 全文貼り替え
3. `step4.md` 全文貼り替え
4. `verify-step4.sh` 全文貼り替え
5. `finish.md` 全文貼り替え
6. sed で他スクリプトにreadlink -f追加
7. `environment-differences.md` に追記
8. `git add -A && git commit && git push`
9. Killercoda Sync → 再起動 → 検証

順調に進めば1時間くらいで検証まで完了します。詰まったら結果を貼ってください。