#!/usr/bin/env python3
"""Killercoda startup supervisor and spoiler-free foreground display (Linux)."""
import argparse
import fcntl
import json
import os
import pathlib
import queue
import signal
import subprocess
import sys
import threading
import time
import traceback
import uuid

STAGES = {
    'docker': 'Docker / Docker Composeの利用確認',
    'resources': '必要な資材の取得',
    'build': 'Dockerイメージのビルド',
    'database': 'DBコンテナの起動・ヘルスチェック',
    'applications': 'APコンテナの起動',
    'normal': '正常業務の準備',
    'scenario': '演習用状態の準備',
    'ready': 'Scenario開始可能状態の確認',
}


def read_json(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


def write_json(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False) + '\n', encoding='utf-8')
    os.replace(temporary, path)


def process_token(pid):
    try:
        fields = pathlib.Path(f'/proc/{int(pid)}/stat').read_text().rsplit(')', 1)[1].split()
        return fields[19] if fields[0] not in ('Z', 'X') else None
    except (OSError, ValueError, IndexError, TypeError):
        return None


def same_process(value):
    token = process_token(value.get('pid'))
    return token is not None and token == value.get('process_token')


class SetupFailure(Exception):
    pass


class SetupTimeout(SetupFailure):
    pass


class Supervisor:
    def __init__(self, options, request):
        self.options = options
        self.directory = options.state_dir
        self.state_path = self.directory / 'state.json'
        self.started = time.monotonic()
        self.stage_started = self.started
        self.stage = ''
        self.completed = set()
        self.open_stage = False
        self.last_write = 0
        self.value = {'run_id': request['run_id'], 'boot_id': request['boot_id'],
                      'pid': os.getpid(), 'process_token': process_token(os.getpid()),
                      'status': 'RUNNING', 'stage': '', 'events': [], 'timings': [],
                      'started': self.started, 'timeout': options.timeout}
        options.ready_file.unlink(missing_ok=True)
        self.log = options.log_file.open('a', encoding='utf-8', buffering=1)
        self.log.write(f'\n=== startup run={request["run_id"]} at={time.time()} ===\n')
        self.save()

    def save(self):
        self.value['heartbeat'] = time.monotonic()
        self.value['stage'] = self.stage
        write_json(self.state_path, self.value)
        self.last_write = time.monotonic()

    def event(self, level, message):
        self.value['events'].append({'level': level, 'message': message})
        self.log.write(f'[{level}] {message}\n')
        self.save()

    def begin(self, stage):
        if stage not in STAGES:
            raise SetupFailure('未知の構築工程')
        if self.stage == stage and self.open_stage:
            return
        self.stage = stage
        self.stage_started = time.monotonic()
        self.open_stage = True
        self.event('INFO', STAGES[stage] + 'を開始します')

    def end(self, stage):
        if stage != self.stage or not self.open_stage:
            raise SetupFailure('構築工程の順序が不正です')
        elapsed = round(time.monotonic() - self.stage_started, 3)
        self.value['timings'].append({'stage': stage, 'seconds': elapsed})
        self.completed.add(stage)
        self.open_stage = False
        self.event('OK', f'{STAGES[stage]}が完了しました ({elapsed:.1f}秒)')

    def progress(self, line):
        if not line.startswith('__LAB_STAGE__ '):
            return
        parts = line.split()
        if len(parts) != 3 or parts[2] not in STAGES:
            raise SetupFailure('構築進捗の形式が不正です')
        action, stage = parts[1:]
        if action == 'begin':
            self.begin(stage)
        elif action == 'end':
            self.end(stage)
        elif action == 'retry':
            self.event('WARN', '演習用状態の準備を再確認しています')
        else:
            raise SetupFailure('構築進捗の操作が不正です')

    def tick(self):
        if time.monotonic() - self.started >= self.options.timeout:
            raise SetupTimeout(f'全体の構築上限{self.options.timeout:g}秒に達しました')
        cancellation = read_json(self.directory / 'cancel.json')
        if cancellation.get('run_id') == self.value['run_id']:
            raise SetupTimeout('Foregroundの監視上限に達しました')
        if time.monotonic() - self.last_write >= 1:
            self.save()

    @staticmethod
    def stop_process(process):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()

    def command(self, args, *, cwd=None, check=True, limit=None):
        self.tick()
        self.log.write('COMMAND ' + repr(args) + '\n')
        started = time.monotonic()
        process = subprocess.Popen(args, cwd=cwd, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, encoding='utf-8',
                                   errors='replace', start_new_session=True,
                                   env={**os.environ, 'LAB_STARTUP_PROGRESS': '1'})
        output = queue.Queue(maxsize=1024)
        def reader():
            try:
                for line in process.stdout:
                    output.put(line)
            finally:
                output.put(None)
        threading.Thread(target=reader, daemon=True).start()
        ended = False
        try:
            while not ended or process.poll() is None:
                self.tick()
                if limit is not None and time.monotonic() - started >= limit:
                    raise SetupTimeout(f'現在のコマンドが上限{limit:g}秒に達しました')
                try:
                    line = output.get(timeout=.2)
                except queue.Empty:
                    continue
                if line is None:
                    ended = True
                else:
                    self.log.write(line)
                    self.progress(line)
            rc = process.wait()
            if check and rc:
                raise SetupFailure(f'工程内コマンドが終了コード{rc}で失敗しました')
            return rc
        except BaseException:
            self.stop_process(process)
            raise
        finally:
            process.stdout.close()

    def build(self):
        self.begin('docker')
        deadline = time.monotonic() + 90
        while self.command(['docker', 'info'], check=False, limit=10):
            if time.monotonic() >= deadline:
                raise SetupTimeout('Dockerの準備が90秒以内に完了しませんでした')
            time.sleep(1)
        if self.command(['docker', 'compose', 'version'], check=False, limit=10):
            self.command(['docker-compose', 'version'], limit=10)
        self.end('docker')
        self.begin('resources')
        repo = pathlib.Path('/root/db-connection-exhaustion-lab')
        lab = pathlib.Path('/root/lab')
        if repo.exists() or lab.exists():
            raise SetupFailure('起動先が既に存在します。Scenarioを新規セッションで開始してください')
        self.command(['git', 'clone', '--depth', '1',
                      'https://github.com/imukairiku/db-connection-exhaustion-lab.git', str(repo)], limit=120)
        import shutil
        shutil.copytree(repo / 'lab', lab)
        for path in (lab / 'scripts').glob('*.sh'):
            path.chmod(path.stat().st_mode | 0o111)
        for name in ('show-connections.sh', 'apply-keepalive-setting.sh', 'retest.sh', 'reset-environment.sh'):
            link = pathlib.Path('/root') / name
            if link.is_symlink():
                link.unlink()
            if link.exists():
                raise SetupFailure('起動用ショートカットの作成先が使用中です')
            link.symlink_to(lab / 'scripts' / name)
        self.end('resources')
        self.begin('build')
        self.command(['bash', str(lab / 'scripts' / 'create-failed-state.sh')], cwd=lab)
        if self.open_stage or self.completed != set(STAGES):
            raise SetupFailure('構築工程の完了確認が不足しています')

    def finish(self, status, reason=''):
        self.value['status'] = status
        self.value['elapsed_seconds'] = round(time.monotonic() - self.started, 3)
        if status == 'SUCCEEDED':
            write_json(self.options.ready_file, {'run_id': self.value['run_id'],
                                                'boot_id': self.value['boot_id']})
            self.event('SUCCESS', '全工程が完了しました。Step 1から演習を開始できます')
        else:
            self.options.ready_file.unlink(missing_ok=True)
            label = STAGES.get(self.stage, '起動受付')
            self.event('ERROR', f'{status}: {label} — {reason}')
        self.save()
        self.log.write('RESULT ' + json.dumps(self.value, ensure_ascii=False) + '\n')
        self.log.close()


def serve(options):
    directory = options.state_dir
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'runner.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        boot = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        until = time.monotonic() + options.startup_wait
        request = {}
        while time.monotonic() < until:
            request = read_json(directory / 'request.json')
            if request.get('boot_id') == boot and same_process(request):
                break
            time.sleep(.2)
        else:
            print('ERROR: foreground request not received', file=sys.stderr)
            return 1
        supervisor = Supervisor(options, request)
        def interrupted(signum, frame):
            raise SetupFailure(f'構築処理がsignal {signum}で中断されました')
        original = {s: signal.signal(s, interrupted) for s in (signal.SIGINT, signal.SIGTERM)}
        try:
            supervisor.build()
            supervisor.finish('SUCCEEDED')
            return 0
        except Exception as error:
            supervisor.log.write(traceback.format_exc())
            supervisor.finish('TIMEOUT' if isinstance(error, SetupTimeout) else 'FAILED', str(error))
            return 1
        finally:
            for s, handler in original.items():
                signal.signal(s, handler)


def watch_run(options, request):
    directory = options.state_dir
    began = time.monotonic()
    shown = 0
    last_notice = began
    print('[INFO] 起動処理の受付を待っています', flush=True)
    while True:
        state = read_json(directory / 'state.json')
        matching = state.get('run_id') == request['run_id'] and state.get('boot_id') == request['boot_id']
        now = time.monotonic()
        if matching:
            for event in state.get('events', [])[shown:]:
                if event['level'] != 'SUCCESS':
                    print(f'[{event["level"]}] {event["message"]}', flush=True)
            shown = len(state.get('events', []))
            status = state.get('status')
            if status == 'SUCCEEDED':
                marker = read_json(options.ready_file)
                if marker.get('run_id') == request['run_id'] and marker.get('boot_id') == request['boot_id']:
                    print('[SUCCESS] 全工程が完了しました。Step 1から演習を開始できます', flush=True)
                    return 0
                print('[ERROR] 完了状態と完了markerが一致しません', flush=True)
                return 1
            if status in ('FAILED', 'TIMEOUT'):
                print(f'[INFO] 詳細ログ: {options.log_file}', flush=True)
                return 1
            if not same_process(state):
                print('[ERROR] 構築処理が終了状態を通知せず停止しました。工程: ' + STAGES.get(state.get('stage'), '起動受付'), flush=True)
                print(f'[INFO] 詳細ログ: {options.log_file}', flush=True)
                return 1
            if now - state['started'] > state['timeout'] + 5:
                write_json(directory / 'cancel.json', {'run_id': request['run_id']})
                print('[ERROR] TIMEOUT: 構築監視の全体上限に達しました。工程: ' + STAGES.get(state.get('stage'), '起動受付'), flush=True)
                print(f'[INFO] 詳細ログ: {options.log_file}', flush=True)
                return 1
            if now - last_notice >= 30:
                fresh = now - state.get('heartbeat', 0) < 15
                level = 'INFO' if fresh else 'WARN'
                message = '構築処理は稼働中です' if fresh else '構築監視の更新が遅れています'
                print(f'[{level}] {message}。工程: {STAGES.get(state.get("stage"), "起動受付")} ({now-state["started"]:.0f}秒経過)', flush=True)
                last_notice = now
        elif now - began > options.startup_wait:
            print('[ERROR] TIMEOUT: Backgroundから起動受付の応答がありません', flush=True)
            print(f'[INFO] 詳細ログ: {options.log_file} / Killercoda Creator Debug', flush=True)
            return 1
        time.sleep(.2)


def watch(options):
    options.state_dir.mkdir(parents=True, exist_ok=True)
    with (options.state_dir / 'watch.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        request = {'run_id': uuid.uuid4().hex,
                   'boot_id': pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                   'pid': os.getpid(), 'process_token': process_token(os.getpid())}
        write_json(options.state_dir / 'request.json', request)
        return watch_run(options, request)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('run', 'watch'))
    parser.add_argument('--state-dir', type=pathlib.Path, default=pathlib.Path('/tmp/lab-startup'))
    parser.add_argument('--ready-file', type=pathlib.Path, default=pathlib.Path('/opt/.lab-ready'))
    parser.add_argument('--log-file', type=pathlib.Path, default=pathlib.Path('/var/log/lab-setup.log'))
    parser.add_argument('--timeout', type=float, default=600)
    parser.add_argument('--startup-wait', type=float, default=90)
    options = parser.parse_args()
    return serve(options) if options.mode == 'run' else watch(options)


if __name__ == '__main__':
    raise SystemExit(main())
