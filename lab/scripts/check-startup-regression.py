#!/usr/bin/env python3
"""Focused startup control tests. No Docker, database or browser operations."""
import contextlib
import importlib.util
import io
import json
import pathlib
import re
import signal
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
FILE = ROOT / 'killercoda/db-connection-exhaustion/assets/startup.py'
spec = importlib.util.spec_from_file_location('startup', FILE)
startup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(startup)


class StartupTests(unittest.TestCase):
    def test_killercoda_asset_and_short_wrappers(self):
        scenario = FILE.parents[1]
        definition = json.loads((scenario / 'index.json').read_text(encoding='utf-8'))
        assets = definition['details']['assets']['host01']
        self.assertNotIn('assets', definition)
        self.assertEqual(assets[0]['file'], 'startup.py')
        self.assertEqual(assets[0]['target'], '/opt/lab-startup/')
        self.assertTrue((scenario / 'assets' / assets[0]['file']).is_file())
        for key, mode in (('background', 'run'), ('foreground', 'watch')):
            wrapper = scenario / definition['details']['intro'][key]
            self.assertEqual(wrapper.read_text().strip().splitlines(),
                             ['#!/usr/bin/env bash', f'python3 /opt/lab-startup/startup.py {mode}'])

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = pathlib.Path(self.temporary.name)
        self.options = types.SimpleNamespace(state_dir=self.directory,
            ready_file=self.directory / 'ready', log_file=self.directory / 'detail.log',
            timeout=5, startup_wait=.05)
        self.request = {'run_id': 'new-run', 'boot_id': 'test-boot',
                        'pid': 123, 'process_token': 'test-token'}
        self.supervisor = None

    def tearDown(self):
        if self.supervisor and not self.supervisor.log.closed:
            self.supervisor.log.close()
        self.temporary.cleanup()

    def start(self):
        self.supervisor = startup.Supervisor(self.options, self.request)
        return self.supervisor

    def observe(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            rc = startup.watch_run(self.options, self.request)
        return rc, output.getvalue()

    def test_success_all_stages_and_no_spoilers(self):
        supervisor = self.start()
        for stage in startup.STAGES:
            supervisor.begin(stage)
            supervisor.end(stage)
        supervisor.log.write('SECRET: AP1 paused, DB connections=12, cause=leftover\n')
        supervisor.finish('SUCCEEDED')
        rc, output = self.observe()
        self.assertEqual(rc, 0)
        self.assertEqual(output.count('[OK]'), 8)
        self.assertEqual(output.count('[SUCCESS]'), 1)
        self.assertNotIn('SECRET', output)
        self.assertNotIn('AP1', output)
        self.assertIn('SECRET', self.options.log_file.read_text())
        self.assertEqual(len(startup.read_json(supervisor.state_path)['timings']), 8)

    def test_old_ready_is_removed_and_wrong_run_is_not_accepted(self):
        startup.write_json(self.options.ready_file, {'run_id': 'old-run'})
        supervisor = self.start()
        self.assertFalse(self.options.ready_file.exists())
        state = dict(supervisor.value, run_id='old-run', status='SUCCEEDED')
        startup.write_json(supervisor.state_path, state)
        startup.write_json(self.options.ready_file, {'run_id': 'old-run'})
        rc, output = self.observe()
        self.assertEqual(rc, 1)
        self.assertIn('TIMEOUT', output)
        self.assertNotIn('[SUCCESS]', output)

    def test_success_with_wrong_marker_rejected(self):
        supervisor = self.start()
        supervisor.finish('SUCCEEDED')
        startup.write_json(self.options.ready_file, {'run_id': 'wrong', 'boot_id': 'test-boot'})
        rc, output = self.observe()
        self.assertEqual(rc, 1)
        self.assertNotIn('[SUCCESS]', output)

    def test_reported_success_not_timed_out_by_late_foreground(self):
        supervisor = self.start()
        supervisor.value['started'] -= 1000
        supervisor.finish('SUCCEEDED')
        rc, output = self.observe()
        self.assertEqual(rc, 0)
        self.assertNotIn('TIMEOUT', output)

    def test_command_failure_reports_real_stage_and_private_cause(self):
        supervisor = self.start()
        supervisor.begin('build')
        with self.assertRaises(startup.SetupFailure) as caught:
            supervisor.command([sys.executable, '-c', 'print("PRIVATE failure detail"); raise SystemExit(7)'])
        supervisor.finish('FAILED', str(caught.exception))
        rc, output = self.observe()
        self.assertEqual(rc, 1)
        self.assertIn('Dockerイメージ', output)
        self.assertIn('7', output)
        self.assertNotIn('PRIVATE', output)
        self.assertIn('PRIVATE', self.options.log_file.read_text())
        self.assertFalse(self.options.ready_file.exists())

    def test_dead_background_detected_without_waiting_for_global_limit(self):
        supervisor = self.start()
        supervisor.begin('database')
        supervisor.value['pid'] = 2147483647
        supervisor.save()
        rc, output = self.observe()
        self.assertEqual(rc, 1)
        self.assertIn('停止', output)
        self.assertIn('DBコンテナ', output)

    def test_alive_silent_command_keeps_heartbeat(self):
        supervisor = self.start()
        before = startup.read_json(supervisor.state_path)['heartbeat']
        supervisor.command([sys.executable, '-c', 'import time; time.sleep(1.3)'])
        after = startup.read_json(supervisor.state_path)['heartbeat']
        self.assertGreater(after, before + .9)
        self.assertEqual(supervisor.value['status'], 'RUNNING')

    def test_timeout_stops_process_group_and_removes_ready(self):
        supervisor = self.start()
        supervisor.begin('build')
        command = [sys.executable, '-c', 'import subprocess,time; p=subprocess.Popen(["sleep","60"]); print("child="+str(p.pid),flush=True); time.sleep(60)']
        with self.assertRaises(startup.SetupTimeout) as caught:
            supervisor.command(command, limit=.3)
        supervisor.finish('TIMEOUT', str(caught.exception))
        child = int(re.search(r'^child=(\d+)$', self.options.log_file.read_text(), re.M).group(1))
        self.assertIsNone(startup.process_token(child))
        self.assertFalse(self.options.ready_file.exists())
        rc, output = self.observe()
        self.assertEqual(rc, 1)
        self.assertIn('TIMEOUT', output)
        self.assertIn('Dockerイメージ', output)

    def test_global_timeout_remains_bounded_even_with_output(self):
        self.options.timeout = .25
        supervisor = self.start()
        with self.assertRaises(startup.SetupTimeout):
            supervisor.command([sys.executable, '-c', 'import time\nwhile True:\n print("working",flush=True); time.sleep(.05)'])

    def test_real_progress_protocol_and_order(self):
        supervisor = self.start()
        supervisor.command([sys.executable, '-c', 'print("__LAB_STAGE__ begin build"); print("__LAB_STAGE__ end build")'])
        self.assertIn('build', supervisor.completed)
        self.assertEqual(len(supervisor.value['timings']), 1)
        with self.assertRaises(startup.SetupFailure):
            supervisor.progress('__LAB_STAGE__ end database')

    def test_retry_does_not_claim_unfinished_stage_ok(self):
        supervisor = self.start()
        supervisor.begin('scenario')
        supervisor.progress('__LAB_STAGE__ retry scenario')
        supervisor.begin('normal')
        self.assertNotIn('scenario', supervisor.completed)
        self.assertFalse(any(e['level'] == 'OK' for e in supervisor.value['events']))

    def test_supervisor_finalizes_success_and_failure(self):
        boot = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        request = {'run_id': 'serve-test', 'boot_id': boot, 'pid': __import__('os').getpid(),
                   'process_token': startup.process_token(__import__('os').getpid())}
        startup.write_json(self.directory / 'request.json', request)
        def build(supervisor):
            for stage in startup.STAGES:
                supervisor.begin(stage)
                supervisor.end(stage)
        with mock.patch.object(startup.Supervisor, 'build', build):
            self.assertEqual(startup.serve(self.options), 0)
        with mock.patch.object(startup.Supervisor, 'build', side_effect=startup.SetupFailure('test failure')):
            self.assertEqual(startup.serve(self.options), 1)
        self.assertFalse(self.options.ready_file.exists())
        self.assertEqual(startup.read_json(self.directory / 'state.json')['status'], 'FAILED')


if __name__ == '__main__':
    unittest.main(verbosity=2)
