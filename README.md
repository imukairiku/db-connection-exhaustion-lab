# DB接続枯渇 調査・復旧ハンズオン演習

AP信頼性試験を想定した、PostgreSQLのDB接続枯渇障害の調査・暫定復旧・恒久対策(TCP Keepalive)を体験する30分ハンズオン演習です。
Killercoda上で受講者へ提供します。開発・一次テストはGoogle Cloud Shellで行います。

> **注意**
> 本リポジトリ内のパスワード・接続情報はすべて演習専用です。本番環境では使用しないでください。
> また `max_connections=20` や短いKeepalive値(idle=20秒など)は障害再現・学習用の意図的な設定であり、本番にそのまま適用しないでください。

## リポジトリ構成

```````````````````````````````text
lab/          共通Docker資材(Cloud Shell / Killercoda 共通で動作)
killercoda/   Killercodaシナリオ定義(step文、verify、background)
docs/         設計・環境差ドキュメント
```````````````````````````````

## アーキテクチャ概要

```````````````````````````````text
Dockerホスト
├── ap-server-1 : 旧現用系AP(Python + Psycopg3、最大12並行の業務処理)
├── ap-server-2 : 待機系AP(heartbeat断で自動昇格)
└── db-server   : PostgreSQL 16(max_connections=20)
```````````````````````````````

障害シナリオ:通信DROP + docker pause により ap-server-1 の接続をDBへ残留させ、
切替後の ap-server-2 が接続枯渇でエラーになる状態を再現します。

---

## 開発環境:Google Cloud Shell

### 前提

- Google Cloud Shell(DockerとDocker Compose v2がプリインストール)
- GitHubアカウントとリポジトリへのpush権限

確認:

```````````````````````````````bash
docker version --format '{{.Server.Version}}'
docker compose version
```````````````````````````````

### 初回セットアップ

```````````````````````````````bash
git clone https://github.com/<your-account>/db-connection-exhaustion-lab.git
cd db-connection-exhaustion-lab
```````````````````````````````

GitHub認証は HTTPS + Personal Access Token、または `gh auth login` を使用してください。
**トークンをリポジトリ内のファイルへ書き込まないでください。**

### 基本動作確認(lab/ 単体)

```````````````````````````````bash
cd lab

# 1. ビルドと起動
./scripts/setup.sh

# 2. 通常負荷(ap-server-1 が12並行で業務処理)
./scripts/start-normal-load.sh
./scripts/show-connections.sh        # AP別の接続数を表示

# 3. 障害投入(通信DROP + pause + 自動切替)
./scripts/inject-failure.sh
./scripts/show-connections.sh        # ap-server-1 の接続が残留し、枯渇状態になる
docker logs --tail 20 ap-server-2    # DB接続エラーを確認

# 4. 暫定復旧(残留接続の終了)
docker exec -it db-server psql -U postgres -d appdb -c \
  "SELECT pid, pg_terminate_backend(pid) FROM pg_stat_activity
   WHERE application_name='ap-server-1' AND pid <> pg_backend_pid();"
docker logs --tail 20 ap-server-2    # 業務処理の回復を確認

# 5. 恒久対策と再試験
./scripts/apply-keepalive-setting.sh
./scripts/retest.sh                  # 時系列で接続数を表示、自動解放を確認

# 6. 後始末
./scripts/reset-environment.sh       # 正常状態へ戻す
# 完全に破棄する場合
docker compose down -v
```````````````````````````````

### 演習開始状態(受講者視点)の再現

Killercodaのbackground.shが作る「障害発生済み」状態をCloud Shellで再現するには:

```````````````````````````````bash
cd lab
./scripts/create-failed-state.sh
```````````````````````````````

### Killercodaのverifyスクリプトの一次確認

verifyスクリプトは環境状態のみを見るため、Cloud Shellでも大部分を確認できます:

```````````````````````````````bash
# 例: 障害状態を作った直後に step1 の verify が成功するか
bash killercoda/db-connection-exhaustion/verify-step1.sh; echo "exit=$?"
```````````````````````````````

---

## Cloud Shell と Killercoda の環境差(重要)

詳細は [docs/environment-differences.md](docs/environment-differences.md) を参照してください。

**以下はCloud Shellでの確認だけでは不十分で、Killercoda上での最終確認が必須です:**

1. **iptables による通信DROP**
   Cloud ShellとKillercodaではカーネル・iptablesバックエンド(legacy/nft)・
   DOCKER-USERチェーンの挙動が異なる可能性があります。
   `inject-failure.sh` は多段フォールバックを持ちますが、どの方式が採用されるかは環境依存です。
2. **Dockerネットワーク**
   サブネット競合、ブリッジ実装差、コンテナ間通信のMTU等。
3. **TCP Keepalive の実際の解放タイミング**
   カーネルパラメータとpause中コンテナへのプローブ挙動は実測が必要です。
   retest.sh の時系列表示で「約35〜40秒で解放」となるかをKillercodaで確認してください。

`inject-failure.sh` は採用した方式を `/tmp/lab-state/drop-method` に記録します。
Killercodaでの最終確認時に必ずこのファイルの内容を確認し、想定方式(iptables/DOCKER-USER)で
動作しているかをチェックしてください:

```````````````````````````````bash
cat /tmp/lab-state/drop-method
```````````````````````````````

---

## Killercodaへの反映手順

1. `lab/` と `killercoda/` の変更をcommitし、GitHubへpushする

```````````````````````````````bash
   git add -A
   git status          # 不要ファイルが含まれていないか必ず確認
   git commit -m "Update lab scripts"
   git push origin main
```````````````````````````````

2. Killercoda(https://killercoda.com/creator)でシナリオリポジトリとして
   本リポジトリを連携し、シナリオパスを `killercoda/db-connection-exhaustion` に設定する
3. push後、Killercoda上でシナリオを開いて動作確認する
   - background.sh の完了時間(受講者がStep1到達までに環境が整うか)
   - 上記「環境差」3項目の実機確認
   - 各stepのverify動作

> background.sh は本リポジトリの `lab/` をKillercoda環境内で取得します。
> リポジトリをprivateにする場合はbackground.shの取得方法(公開tarball不可)を見直す必要があります。
> 演習資材は原則publicリポジトリを推奨します。

## テストチェックリスト

- [ ] Cloud Shell: setup.sh → 3コンテナhealthy/running
- [ ] Cloud Shell: 通常負荷で ap-server-1 の接続が最大12前後で増減
- [ ] Cloud Shell: inject-failure.sh 後、残留8本以上 + ap-server-2 接続エラー
- [ ] Cloud Shell: pg_terminate_backend で ap-server-2 回復
- [ ] Cloud Shell: retest.sh でKeepalive自動解放を確認
- [ ] Cloud Shell: 各verifyスクリプトが期待どおりの終了コード
- [ ] Killercoda: drop-method が想定方式か
- [ ] Killercoda: Keepalive解放タイミングが35〜40秒程度か
- [ ] Killercoda: background.sh 完了時間、メモリ使用量
- [ ] Killercoda: 30分で完走できるか通し実施

## セキュリティ・コミット時の注意

- 認証情報(GitHubトークン、gcloud認証情報)は絶対にコミットしない
- `/tmp/lab-state/` 等の一時ファイル、実行時ログはコミットしない(.gitignore済み)
- 演習用パスワード(lab-app-pass等)はコード内に平文で存在するが、
  これは演習専用であることを各ファイル冒頭に明記している
