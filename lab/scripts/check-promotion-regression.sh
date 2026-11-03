#!/usr/bin/env bash
# Focused local regression: fake Docker transport, real Bash/Python state checks.
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fixture_dir=$(mktemp -d)
export LAB_STATE_DIR="$fixture_dir/state"
mkdir -p "$LAB_STATE_DIR"
trap 'rm -f "$fixture_dir/logs"; rmdir "$LAB_STATE_DIR" "$fixture_dir"' EXIT
role_mode=active
runtime_state=running
logs_rc=0
exec_calls=0

docker() {
  case "$1" in
    compose) return 0 ;;
    inspect) printf '%s\n' "$runtime_state" ;;
    logs) cat "$fixture_dir/logs"; return "$logs_rc" ;;
    exec)
      exec_calls=$((exec_calls + 1))
      local mode="$role_mode"
      if [ "$mode" = transition ]; then
        mode=active
        [ "$exec_calls" -gt 1 ] || mode=standby
      fi
      ROLE_MODE="$mode" python3 -c '
import json,os,pathlib,sys,tempfile
code=sys.stdin.read()
with tempfile.TemporaryDirectory() as directory:
    marker=pathlib.Path(directory)/"role.json"
    ticks=pathlib.Path("/proc/self/stat").read_text().rsplit(")",1)[1].split()[19]
    state={"role":"ACTIVE","ap_name":sys.argv[1],"pid":os.getpid(),"process_start_ticks":ticks}
    mode=os.environ["ROLE_MODE"]
    if mode=="standby": state["role"]="STANDBY"
    if mode=="stale": state["process_start_ticks"]="-1"
    if mode=="wrong_ap": state["ap_name"]="ap-server-1"
    if mode=="dead": state["pid"]=2147483647
    if mode!="missing": marker.write_text("invalid" if mode=="malformed" else json.dumps(state))
    exec(compile(code.replace("/tmp/ap-role.json",str(marker)),"role-check","exec"))
' "${@: -1}"
      ;;
    *) echo "unexpected Docker command: $*" >&2; return 99 ;;
  esac
}
# Advance the polling clock without actually sleeping in unit regressions.
sleep() { SECONDS=$((SECONDS + $1)); }
source "$SCRIPT_DIR/common.sh"

python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text("PROMOTED to ACTIVE\n"+"worker output xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n"*100000)' "$fixture_dir/logs"
if tail -n 100 "$fixture_dir/logs" | grep -e 'PROMOTED to ACTIVE' >/dev/null; then
  echo 'FAIL: tail-window reproduction unexpectedly matched' >&2; exit 1
fi
echo 'REPRODUCED: promotion disappears from tail 100'
if python3 -c 'import sys; sys.stdout.write("PROMOTED to ACTIVE\n"); sys.stdout.flush(); sys.stdout.write("x"*8388608); sys.stdout.flush()' 2>/dev/null | grep -q 'PROMOTED to ACTIVE'; then
  echo 'FAIL: SIGPIPE reproduction unexpectedly succeeded' >&2; exit 1
else
  pipeline_status=("${PIPESTATUS[@]}")
  [ "${pipeline_status[0]}" -ne 0 ] && [ "${pipeline_status[1]}" = 0 ]
  echo "REPRODUCED: old pipeline producer=${pipeline_status[0]}, grep=${pipeline_status[1]} (match rejected under pipefail)"
fi

wait_for_log_pattern ap-server-2 'PROMOTED to ACTIVE' 1
logs_rc=1
if wait_for_log_pattern ap-server-2 'PROMOTED to ACTIVE' 1; then
  echo 'FAIL: Docker log error accepted' >&2; exit 1
fi
logs_rc=0
if wait_for_log_pattern ap-server-2 'never-present' 1; then
  echo 'FAIL: absent log accepted' >&2; exit 1
fi

for role_mode in standby stale missing malformed dead wrong_ap; do
  if wait_for_ap_active ap-server-2 1; then
    echo "FAIL: invalid role accepted: $role_mode" >&2; exit 1
  fi
done
role_mode=active
runtime_state=paused
if wait_for_ap_active ap-server-2 1; then
  echo 'FAIL: paused container accepted' >&2; exit 1
fi
runtime_state=running
wait_for_ap_active ap-server-2 1
exec_calls=0
role_mode=transition
wait_for_ap_active ap-server-2 10
[ "$exec_calls" = 2 ] || { echo 'FAIL: standby/active transition not observed'; exit 1; }

python3 - "$SCRIPT_DIR/../ap/failover.py" <<'PY'
import importlib.util,json,pathlib,sys,tempfile,types
from unittest import mock

sys.modules['app']=types.SimpleNamespace(start_workers=mock.Mock())
sys.modules['healthcheck']=types.SimpleNamespace(start_heartbeat=mock.Mock())
spec=importlib.util.spec_from_file_location('failover_under_test',sys.argv[1])
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
class StopLoop(Exception): pass
with tempfile.TemporaryDirectory() as directory:
    module.ROLE_STATE_FILE=pathlib.Path(directory)/'role.json'
    module.publish_role('ACTIVE')
    value=json.loads(module.ROLE_STATE_FILE.read_text())
    ticks=pathlib.Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19]
    assert value['process_start_ticks']==ticks
    assert not list(pathlib.Path(directory).glob('*.tmp'))
    module.ROLE='standby'
    def check_startup():
        assert json.loads(module.ROLE_STATE_FILE.read_text())['role']=='STARTING'
    with mock.patch.object(module,'run_standby',side_effect=check_startup): module.main()
    published=[]
    original=module.publish_role
    def publish(role):
        published.append(role)
        original(role)
    def workers_started():
        assert published==['STANDBY']
    with mock.patch.object(module,'publish_role',side_effect=publish), \
         mock.patch.object(module,'heartbeat_age',return_value=999), \
         mock.patch.object(module.app,'start_workers',side_effect=workers_started), \
         mock.patch.object(module.time,'sleep',side_effect=StopLoop):
        try: module.run_standby()
        except StopLoop: pass
    assert published==['STANDBY','ACTIVE'],published
    with mock.patch.object(module,'heartbeat_age',return_value=999), \
         mock.patch.object(module.app,'start_workers',side_effect=RuntimeError('worker startup failed')):
        try: module.run_standby()
        except RuntimeError: pass
        else: raise AssertionError('worker failure swallowed')
    assert json.loads(module.ROLE_STATE_FILE.read_text())['role']=='STANDBY'
print('PASS: role publication, startup reset, promotion ordering, worker failure')
PY
echo 'PROMOTION-REGRESSION PASS (transport mocked; Killercoda retest still required)'
