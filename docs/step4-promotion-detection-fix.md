# Step 4再試験の昇格検出修正（2026-11-03）

対象: 既存4 Step Scenario。新しい7 Step Scenarioには変更しない。

## 実測報告と原因分析

Killercodaでは恒久対策`idle_in_transaction_session_timeout=30s`、AP1接続12本、通信DROP、
AP1 pauseまで成功した。AP2は12:44:34.843 UTCに起動し、12:44:55 UTCに
`PROMOTED to ACTIVE`を出したが、retestの40秒待機がFAILした。
起動から昇格まで約20.157秒で、昇格自体の失敗を示す報告ではない。

旧`wait_for_log_pattern`は`docker logs --tail 100 | grep -q`を使っていた。
限定回帰試験で次の両方を再現した。

- 昇格後に100行超のログが流れると、末尾100行に昇格イベントが含まれなくなる。
- 大量出力の途中で`grep -q`が一致して終了すると、上流がBrokenPipeで非0終了し、
  `pipefail`により検索一致があっても全体がFAILになる。

元の全ログ、各ポーリング時の末尾100行、PIPESTATUSは提供されていないため、
Killercodaの当該実行でどちらが発火したかの一意な断定はしない。

## 修正

APは`STARTING → STANDBY → ACTIVE`を`/tmp/ap-role.json`へatomicに記録する。
ACTIVEは業務ワーカー開始後に記録し、PIDとLinuxプロセス開始tickに紐づける。
再起動前の状態ファイル、STANDBY、存在しないプロセス、pause状態は昇格成功と判定しない。

`retest.sh`と初期障害構築はログ検索から現在のACTIVE状態の待機へ変更した。
残留接続数の自動解放待機、AP2の実業務成功照合、再試験完了markerの条件は維持する。
他のログ検索は行数制限を外し、Docker出力を一時ファイルに読み切ってから検索する。
Step 4 verifyのログfallbackも`grep -q`を使わず出力を読み切る。

## 検証と再実測

`bash lab/scripts/check-promotion-regression.sh`で上記2件の再現、ログ検索の成功・未一致・
Dockerエラー、STANDBYからACTIVEへの遷移、古い開始tick・欠損・不正JSON・死んだPID・
別AP名・pausedの拒否、状態の初期化、ワーカー起動失敗時の非ACTIVEを確認した。
Docker通信は置き換えており、Killercoda実測PASSとは扱わない。

pushとSync Now後は既存4 Step Scenarioを終了して新規セッションで開始する。
背景構築によるAPイメージ再buildを待つ（既に開いている古いAPへコードは反映されない）。
Step 1〜3を教材どおり進め、Step 4で恒久対策適用後に`/root/lab/scripts/retest.sh`を実行する。
現在プロセスACTIVEの確認、AP1接続0、自動業務回復、再試験成功、Step 4 CHECK成功を観察する。
この実測結果を受け取るまでブラウザE2Eの当該FAILは解消確定しない。
