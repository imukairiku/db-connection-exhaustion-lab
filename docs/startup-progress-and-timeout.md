# 既存4 Step Scenarioの起動進捗・監視改善

状態: 実測準備。ブラウザ受入は0/6確認済み。既存PASS記録は変更しない。

## 変更と実処理の対応

Killercoda公式例に合わせ、`details.assets.host01`で`assets/startup.py`を
`/opt/lab-startup/`へ配布する。ForegroundとBackgroundの本文はそれぞれ
`python3 /opt/lab-startup/startup.py watch`、`... run`の1行だけとする。
Foregroundへ長いBash処理を流さない。

受講者には以下の工程の開始・確認済み完了だけを表示する。

1. Docker / Compose: daemonとComposeコマンドの利用を確認。
2. 資材取得: 既存Scenarioリポジトリをcloneし、lab資材とショートカットを配置。
3. ビルド: 既存`setup.sh`の`compose build`成功を確認。
4. DB起動: DBだけを起動し、healthyを確認。
5. AP起動: APを起動し、両コンテナのrunningを確認。
6. 正常業務: 既存の正常化・正常負荷・接続準備の成功を確認。
7. 演習用状態: 既存の障害注入・自動昇格・残留接続・DB接続失敗を内部で検証。
8. 開始可能状態: DB healthy、AP状態、現在プロセスACTIVE、残留接続を再確認。

6〜8の具体的なAP名・切替・接続数は初期の受講者表示へ出さない。
詳細な標準出力・標準エラー・終了コード・コマンド・例外は`/var/log/lab-setup.log`に記録する。
再試行時はWARNを表示し、未完了工程へOKを表示しない。
進捗通知は起動監視の環境変数があるときだけ有効で、通常のretest/reset操作では無効。

## 状態・タイムアウト

Foregroundが固有run IDを要求し、Backgroundが現在bootと生存する要求元プロセスを照合して開始する。
`/tmp/lab-startup/state.json`にはrun ID、RUNNING/SUCCEEDED/FAILED/TIMEOUT、工程、
PIDと開始tick、heartbeat、工程別秒数、全体秒数をatomicに記録する。
古い要求・state・空の`/opt/.lab-ready`だけでは完了判定しない。

開始時に過去のreadyを除去し、全工程と最終検証の正常終了後だけ、同一run IDを持つreadyを作る。
失敗・signal中断・timeoutではreadyを除去し、ForegroundへERRORと工程・診断ログの場所を示す。
BackgroundがSIGKILL等で通知せず停止した場合も、ForegroundはPIDと開始tickで停止を検出する。
ログが無い間も監視ループがheartbeatを更新するため、長い静かなビルドを停止と誤認しない。
timeout時は実行コマンドのprocess groupをTERM/KILLで停止し、遅れてreadyが作られるのを防ぐ。
最終完了が記録されていれば、Foregroundの表示開始が遅れてもtimeoutにしない。

全体上限600秒は暫定で維持する。受付待ちは90秒、Docker待機90秒、Git取得120秒にも上限を設ける。
現在までのKillercoda起動時間分布は提供されていないため、600秒が最適という実測判断はできない。
今回の工程別`timings`と`elapsed_seconds`を新規セッションで収集し、遅延した工程と終了状態を
見て上限を評価する。時間の延長だけを対策にはしない。

## 検証

`python3 lab/scripts/check-startup-regression.py`で制御部を限定検証する。
正常完了、古いmarker・別run拒否、marker不一致拒否、遅れたForegroundでの完了受理、
コマンド失敗、異常停止、無出力処理のheartbeat、全体timeout、子プロセス群停止、
工程順序、再試行、asset・短いwrapper定義を確認する。
実Docker起動とKillercodaブラウザ受入は別途必要。新7 Step Scenarioは変更しない。

## Sync Now後の受入（未確認）

push → Sync Now → 既存4 Step Scenarioを終了して新規セッションで開始する。

- [ ] 実工程に沿ってINFOとOKが順に表示される。
- [ ] Foregroundの長いBashコードが表示されない。
- [ ] 全工程確認後にSUCCESSが表示される。
- [ ] 失敗・timeoutが正常完了と区別され、工程と診断先が分かる。
- [ ] AP障害・切替・原因・具体的接続数が初期表示へ漏れない。
- [ ] Step 1を開始でき、既存Step 1〜4、CHECK、retest、resetを実施できる。

初回起動後は`/tmp/lab-startup/state.json`の`status`、`timings`、`elapsed_seconds`を収集する。
問題時は初期画面の表示全文と`/var/log/lab-setup.log`で原因を確認する。
