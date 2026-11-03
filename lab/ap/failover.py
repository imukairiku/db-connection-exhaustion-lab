"""
演習用 簡易冗長切替(エントリポイント)

- ROLE=active  : heartbeat書き込みを開始し、即座に業務ワーカーを起動する
- ROLE=standby : heartbeatファイルを監視し、HEARTBEAT_TIMEOUT 秒以上
                 更新が途絶えたら現用系へ昇格して業務ワーカーを起動する

KeepalivedやPacemaker等は使用しない、演習用の簡易実装です。
"""

import datetime
import json
import os
import pathlib
import sys
import time

import app
import healthcheck

ROLE = os.environ.get("ROLE", "standby").lower()
AP_NAME = os.environ.get("AP_NAME", "ap-server-x")
HEARTBEAT_FILE = os.environ.get("HEARTBEAT_FILE", "/shared/heartbeat-ap1")
HEARTBEAT_TIMEOUT = float(os.environ.get("HEARTBEAT_TIMEOUT", "10"))
CHECK_INTERVAL = float(os.environ.get("CHECK_INTERVAL", "2"))
ROLE_STATE_FILE = pathlib.Path('/tmp/ap-role.json')


def publish_role(role: str) -> None:
    """Publish role atomically, bound to this process rather than an old restart."""
    start_ticks = pathlib.Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()[19]
    value = {'role': role, 'ap_name': AP_NAME, 'pid': os.getpid(),
             'process_start_ticks': start_ticks}
    temporary = ROLE_STATE_FILE.with_name(ROLE_STATE_FILE.name + f'.{os.getpid()}.tmp')
    temporary.write_text(json.dumps(value) + '\n', encoding='utf-8')
    os.replace(temporary, ROLE_STATE_FILE)


def log(level: str, msg: str) -> None:
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{ts} [{level}] {msg}", flush=True)


def heartbeat_age(start_time: float) -> float:
    """heartbeatファイルの最終更新からの経過秒を返す。
    ファイルが無い場合はプロセス起動時刻からの経過秒を返す
    (現用系が一度も起動しない場合でも昇格できるようにするため)。
    """
    try:
        mtime = os.path.getmtime(HEARTBEAT_FILE)
        return time.time() - mtime
    except OSError:
        return time.time() - start_time


def run_active() -> None:
    log("INFO", f"{AP_NAME}: starting as ACTIVE")
    healthcheck.start_heartbeat()
    app.start_workers()
    publish_role('ACTIVE')
    while True:
        time.sleep(5)


def run_standby() -> None:
    publish_role('STANDBY')
    log(
        "INFO",
        f"{AP_NAME}: starting as STANDBY "
        f"(monitoring {HEARTBEAT_FILE}, timeout={HEARTBEAT_TIMEOUT}s)",
    )
    start_time = time.time()
    while True:
        age = heartbeat_age(start_time)
        if age > HEARTBEAT_TIMEOUT:
            log(
                "WARN",
                f"{AP_NAME}: heartbeat lost for {age:.1f}s "
                f"(> {HEARTBEAT_TIMEOUT}s)",
            )
            app.start_workers()
            publish_role('ACTIVE')
            log("WARN", f"{AP_NAME}: PROMOTED to ACTIVE (failover)")
            while True:
                time.sleep(5)
        time.sleep(CHECK_INTERVAL)


def main() -> None:
    publish_role('STARTING')
    if ROLE == "active":
        run_active()
    elif ROLE == "standby":
        run_standby()
    else:
        log("ERROR", f"unknown ROLE: {ROLE} (use 'active' or 'standby')")
        sys.exit(1)


if __name__ == "__main__":
    main()
