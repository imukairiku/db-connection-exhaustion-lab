-- =============================================================================
-- 演習用データベース初期化SQL
--   - appdb データベースと appuser ユーザーを作成
--   - 業務処理履歴テーブル job_history を作成
--   - パスワードは演習専用。本番環境では使用しないこと。
-- =============================================================================

-- 業務用ユーザー(演習専用パスワード)
CREATE ROLE appuser WITH LOGIN PASSWORD 'lab-app-pass';

-- 業務用データベース
CREATE DATABASE appdb OWNER appuser ENCODING 'UTF8';

-- 以降は appdb に接続して実行
\connect appdb

-- 業務処理履歴テーブル
CREATE TABLE job_history (
    id          bigserial PRIMARY KEY,
    request_id  text        NOT NULL,           -- 業務処理ごとの一意ID
    ap_name     text        NOT NULL,           -- 処理を実行したAP名
    duration_s  integer     NOT NULL,           -- 想定処理時間(秒)
    status      text        NOT NULL,           -- 'success' など
    started_at  timestamptz NOT NULL,
    finished_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_job_history_ap_name ON job_history (ap_name, finished_at DESC);

ALTER TABLE job_history OWNER TO appuser;

-- 動作確認用: 接続状況を見やすくするビュー(管理用)
CREATE VIEW v_connections AS
SELECT
    application_name,
    client_addr,
    state,
    count(*) AS connections
FROM pg_stat_activity
WHERE datname = 'appdb'
GROUP BY application_name, client_addr, state
ORDER BY application_name;

GRANT SELECT ON v_connections TO appuser;
