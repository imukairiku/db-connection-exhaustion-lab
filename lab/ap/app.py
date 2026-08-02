"""
演習用 疑似AP 業務処理ワーカー

- 最大 MAX_WORKERS 件の業務処理を並行実行する
- 各業務処理の流れ:
    1. 一意な request_id を生成
    2. DBへ新規接続(application_name にAP名を設定)
    3. SQLを実行(pg_sleep で 1/3/10 秒の処理を模擬)
    4. 処理履歴を job_history へ記録
    5. 正常終了時にDB接続を閉じる
- 接続プールは使用せず、業務処理ごとに接続を作成・終了する
  (障害時に接続が残留する挙動を分かりやすくするための演習用設計)

注意: 本コード内の接続情報は演習専用です。本番環境では使用しないでください。
"""

import datetime
import os
import random
import sys
import threading
import time
import uuid

import psycopg

# ---- 設定(環境変数から取得) ----
AP_NAME = os.environ.get("AP_NAME", "ap-server-x")
DB_HOST = os.environ.get("DB_HOST", "db-server")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "appdb")
DB_USER = os.environ.get("DB_USER", "appuser")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "lab-app-pass")  # 演習専用
MAX_WORKERS = int(os.environ.get("MAX_WORKERS", "12"))

CONNECT_TIMEOUT = int(os.environ.get("CONNECT_TIMEOUT", "5"))
RETRY_INTERVAL = float(os.environ.get("RETRY_INTERVAL", "3"))

# 処理時間の混在(1秒 / 3秒 / 10秒)。長めを多くして並行数を保つ。
DURATIONS = [1, 3, 3, 10, 10]

_running = threading.Event()
_running.set()


def log(level: str, msg: str) -> None:
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{ts} [{level}] {msg}", flush=True)


def run_one_job(worker_id: int) -> None:
    """業務処理を1件実行する。接続は処理ごとに作成・終了する。"""
    request_id = uuid.uuid4().hex[:12]
    duration = random.choice(DURATIONS)
    started_at = datetime.datetime.now(datetime.timezone.utc)

    conn = None
    try:
        conn = psycopg.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD,
            application_name=AP_NAME,
            connect_timeout=CONNECT_TIMEOUT,
        )
    except Exception as exc:
        # 接続枯渇時はここで
        # "FATAL: remaining connection slots are reserved ..." 等が発生する
        log(
            "ERROR",
            f"DB connection failed: worker={worker_id} "
            f"request_id={request_id} detail={exc}",
        )
        time.sleep(RETRY_INTERVAL)
        return

    try:
        with conn:
            with conn.cursor() as cur:
                # 業務処理の模擬(1/3/10秒)
                cur.execute("SELECT pg_sleep(%s);", (duration,))
                # 処理履歴の記録
                cur.execute(
                    """
                    INSERT INTO job_history
                        (request_id, ap_name, duration_s, status, started_at)
                    VALUES (%s, %s, %s, %s, %s);
                    """,
                    (request_id, AP_NAME, duration, "success", started_at),
                )
        log(
            "INFO",
            f"job SUCCESS: worker={worker_id} "
            f"request_id={request_id} duration={duration}s",
        )
    except Exception as exc:
        log(
            "ERROR",
            f"job FAILED: worker={worker_id} "
            f"request_id={request_id} detail={exc}",
        )
        time.sleep(RETRY_INTERVAL)
    finally:
        try:
            conn.close()
        except Exception:
            pass


def worker_loop(worker_id: int) -> None:
    log("INFO", f"worker {worker_id} started (ap={AP_NAME})")
    while _running.is_set():
        run_one_job(worker_id)
        # 業務処理間の小休止(接続の作成・終了を繰り返す)
        time.sleep(random.uniform(0.2, 0.8))


def start_workers() -> list:
    """MAX_WORKERS 本のワーカーを起動してスレッドリストを返す。"""
    log("INFO", f"starting {MAX_WORKERS} workers (ap={AP_NAME})")
    threads = []
    for i in range(1, MAX_WORKERS + 1):
        t = threading.Thread(target=worker_loop, args=(i,), daemon=True)
        t.start()
        threads.append(t)
        time.sleep(0.1)  # 起動を少しずらす
    return threads


def stop_workers() -> None:
    _running.clear()


if __name__ == "__main__":
    # 単体起動(デバッグ用)。通常は failover.py 経由で起動される。
    try:
        start_workers()
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        stop_workers()
        sys.exit(0)
