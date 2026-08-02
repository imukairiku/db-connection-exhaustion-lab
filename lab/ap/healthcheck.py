"""
演習用 heartbeat 書き込みモジュール

- ACTIVE側のAPが、共有ボリューム上の heartbeat ファイルへ
  一定間隔でタイムスタンプを書き込む
- docker pause されると書き込みが止まり、STANDBY側(failover.py)が
  途絶を検知して昇格する
- DBを経由しないため、DB障害とAP生死判定が分離される
"""

import datetime
import os
import threading
import time

HEARTBEAT_FILE = os.environ.get("HEARTBEAT_FILE", "/shared/heartbeat-ap1")
HEARTBEAT_INTERVAL = float(os.environ.get("HEARTBEAT_INTERVAL", "2"))


def _log(msg: str) -> None:
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{ts} [INFO] {msg}", flush=True)


def _heartbeat_loop() -> None:
    _log(
        f"heartbeat writer started: file={HEARTBEAT_FILE} "
        f"interval={HEARTBEAT_INTERVAL}s"
    )
    while True:
        try:
            with open(HEARTBEAT_FILE, "w") as f:
                f.write(str(time.time()))
        except OSError as exc:
            _log(f"heartbeat write failed: {exc}")
        time.sleep(HEARTBEAT_INTERVAL)


def start_heartbeat() -> threading.Thread:
    """heartbeat書き込みスレッドを起動する。"""
    t = threading.Thread(target=_heartbeat_loop, daemon=True)
    t.start()
    return t
