# Cloud Shell / Killercoda 環境差一覧

開発(Google Cloud Shell)と本番提供(Killercoda)の環境差と、それぞれの確認方針です。

| # | 項目 | Google Cloud Shell | Killercoda | 影響とリスク | 最終確認 |
|---|------|--------------------|------------|--------------|----------|
| 1 | 実体 | GCE上のコンテナ環境(Debianベース、ホームのみ永続) | 使い捨てVM(Ubuntu) | セッション消滅タイミングが異なる | 両方 |
| 2 | Docker | プリインストール、Compose v2 | プリインストール(バージョンはイメージ依存) | composeサブコマンド仕様差は小 | Killercoda |
| 3 | **iptables** | 利用可能だが、Cloud Shell自体がコンテナのためカーネル機能に制約がある場合あり | 環境イメージにより legacy/nft、DOCKER-USER の実効性が異なる | **通信DROPが効かない/解除漏れの可能性** | **Killercoda必須** |
| 4 | **Dockerネットワーク** | 一般的なbridge。172.30.0.0/24 が既存と競合する可能性 | 同左。加えて環境側の予約サブネットに注意 | サブネット競合で起動失敗 | **Killercoda必須** |
| 5 | **TCP Keepalive** | ホストカーネル既定値。setsockopt単位で有効 | カーネル・pause中コンテナへのプローブ挙動が要実測 | **解放時間が想定(約35〜40秒)とずれる可能性** | **Killercoda必須** |
| 6 | メモリ | 標準で比較的余裕あり | 無料枠は小さい(目安2GB程度) | OOMでDB/APが落ちる | Killercoda |
| 7 | ネットワーク到達性 | 制限少 | イメージpull・GitHub取得は可能だが速度変動あり | background.sh の完了遅延 | Killercoda |
| 8 | 実行ユーザー | 一般ユーザー + sudo | root | sudo有無のスクリプト分岐が必要 | 両方 |
| 9 | 永続性 | $HOME のみ永続、/tmp は揮発 | 全て揮発 | 状態ファイルは毎回作り直す前提の設計 | - |
| 10 | nsenter / tc | カーネル権限次第で不可の場合あり | 概ね可(要確認) | DROPフォールバック段数に影響 | **Killercoda必須** |

## スクリプト側の吸収方針

- `common.sh` で sudo の要否を自動判定する(`id -u` が0以外なら `sudo` を付与)
- `inject-failure.sh` は方式を自動選択し、採用方式を `/tmp/lab-state/drop-method` に記録する
- 通信DROPのフォールバック順:
  1. `iptables -I DOCKER-USER`(ホスト)
  2. `iptables -I FORWARD`(ホスト)
  3. `nsenter` + コンテナnetns内 iptables
  4. `nsenter` + `tc qdisc netem loss 100%`
  5. すべて不可 → エラー終了し制約を表示
- `clear-failure.sh` は記録方式に加え、全方式のクリーンアップを冪等に試行する

## Cloud Shell固有の注意

- Cloud Shellはセッションが切れるとDockerコンテナ・イメージが消えることがある
  (ホームディレクトリ以外は非永続)。再開時は `setup.sh` からやり直す。
- Cloud Shell上のiptables検証は「スクリプトのロジック確認」まで。
  実効性の担保はKillercodaで行う。
