# =============================================================================
# 演習用 疑似APサーバ イメージ
#   - Python 3.12 + Psycopg 3
#   - ROLE=active  : 起動時から業務処理を実行(ap-server-1)
#   - ROLE=standby : heartbeat監視し、途絶時に昇格(ap-server-2)
# =============================================================================
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py healthcheck.py failover.py ./

ENV PYTHONUNBUFFERED=1

# failover.py がエントリポイント(ROLEに応じてapp.pyのワーカーを起動)
CMD ["python", "failover.py"]
