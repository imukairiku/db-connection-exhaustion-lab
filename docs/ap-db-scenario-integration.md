# 新Scenarioの追加記録

既存Scenarioは `killercoda/db-connection-exhaustion`（4 Step）。
追加Scenarioは `killercoda/ap-db-connection-exhaustion`（7 Step）。
既存Scenario、`lab/`、既存README、既存設定は変更していない。

追加先リポジトリの基準commitは `1ceb79d`。
新Scenarioは開発元
`https://github.com/imukairiku/ap-db-connection-exhaustion-lab.git`
のcommit `0bdb03aa7390089044bda01c84ba740c3565b31d` を固定取得する。
このcommitにはPhase 7 APのretry実装と実測記録が含まれる。
教材本文とverifyは同commitから移植した。

## 起動時の依存関係

background → GitHub取得 → 固定commit checkout →
`scripts/scenario-reset.sh` → `scripts/scenario-inject.sh`。
実行時のCompose定義は開発元の `tests/test-16.compose.yml`。
`phase7/`、`phase0/`、`phase2/test06/`、`scripts/` は開発元をcloneして解決する。
verifyは `/root/ap-db-connection-exhaustion-lab/scripts/phase7-step-verify.py` を使う。

既存Scenarioの作業場所 `/root/lab`、取得先 `/root/db-connection-exhaustion-lab`、
ready marker `/opt/.lab-ready` と新Scenarioのパスは異なる。
新ScenarioのDocker projectは `phase7-` 接頭辞で、既存の固定コンテナ名を使用しない。
新Scenario専用のready/failed markerとforeground待機を設けた。

## 認識と検証

`structure.json` は追加先に存在しない。
同じ `killercoda/` 配下の2つのScenarioディレクトリを維持し、
新Scenarioの `index.json` と全参照ファイルを確認する。
既存ファイルが基準commitと同一であることをGit差分で確認する。

静的検証は実施。新ScenarioのブラウザE2E、Sync Now後の2件表示、
クリーン環境からの実起動は未確認であり、利用者の受入確認で実測する。
開発元のTEST-00〜18のPASS記録・履歴は変更しない。
