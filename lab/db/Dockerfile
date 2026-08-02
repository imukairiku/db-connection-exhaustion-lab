# =============================================================================
# 演習用 PostgreSQL イメージ
#   - postgres:16 公式イメージをベースに、演習用設定と初期化SQLを組み込む
#   - パスワード等はすべて演習専用。本番環境では使用しないこと。
# =============================================================================
FROM postgres:16

# 演習用のカスタム設定ファイル
COPY postgresql.conf /etc/postgresql/postgresql.conf

# 初期化SQL(初回起動時に docker-entrypoint-initdb.d 経由で実行される)
COPY init.sql /docker-entrypoint-initdb.d/10-init.sql

# カスタム設定ファイルを使用して起動
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
