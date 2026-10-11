import argparse
import hashlib
import json
import os
import pathlib
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True)
args = parser.parse_args()
repo = pathlib.Path(__file__).resolve().parents[2]
output = pathlib.Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=False)
data = output / 'data'
registry = output / 'registry'
sockets = pathlib.Path(tempfile.mkdtemp(prefix='bv752-', dir='/tmp'))
name = 'backup-proof'
env = dict(os.environ, BARKVISOR_INSTANCE_DIR=str(registry), BARKVISOR_SOCKET_DIR=str(sockets), DOCKER_HOST='unix://' + str(output / 'no-docker.sock'))
records = []
meta = None


def command(argv, extra=None):
    result = subprocess.run(argv, cwd=repo, env=dict(env, **(extra or {})), capture_output=True, text=True, timeout=120)
    records.append({'command': argv, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout


def start(injected=False):
    global meta
    for name_file in ['http.port', 'agent.port']:
        (data / name_file).unlink(missing_ok=True)
    time.sleep(1.2)
    extra = {'LD_PRELOAD': str(output / 'failwrite.so'), 'BARKVISOR_PROOF_BACKUP_DIRECTORY': str(data / 'backups')} if injected else None
    raw = command(['bash', 'scripts/dev-instance.sh', 'start', '--name', name, '--data-dir', str(data), '--skip-build'], extra)
    meta = json.loads(raw)
    assert meta['port'] != 7777
    records[-1]['stdout'] = json.dumps({k: meta[k] for k in ['name', 'url', 'port', 'agentPort', 'pid', 'dataDir']})


def stop():
    global meta
    command(['bash', 'scripts/dev-instance.sh', 'stop', '--name', name, '--keep'])
    meta = None


def request(method, path, body=None):
    token = (registry / name / 'token').read_text().strip()
    headers = {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token}
    req = urllib.request.Request(meta['url'] + '/api' + path, method=method, data=None if body is None else json.dumps(body).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=30) as response:
        result = json.loads(response.read())
        records.append({'method': method, 'path': path, 'request': body, 'status': response.status, 'response': result})
        return result


def backup_rows(path):
    with sqlite3.connect('file:' + str(path) + '?mode=ro', uri=True) as database:
        assert database.execute('PRAGMA quick_check').fetchall() == [('ok',)]
        return database.execute("SELECT name FROM networks WHERE name = 'retained-proof-network'").fetchall()


try:
    revision = command(['git', 'rev-parse', 'HEAD']).strip()
    command(['uname', '-a'])
    command(['swift', '--version'])
    command(['cc', '-shared', '-fPIC', '-o', str(output / 'failwrite.so'), 'verification/audit-752/failwrite.c', '-ldl'])
    start()
    request('POST', '/networks', {'name': 'retained-proof-network', 'mode': 'nat'})
    stop()
    start()
    stop()
    backups = sorted((data / 'backups').glob('db-*.sqlite'))
    good = next(path for path in reversed(backups) if backup_rows(path))
    digest = hashlib.sha256(good.read_bytes()).hexdigest()
    records.append({'known_good_backup': good.name, 'bytes': good.stat().st_size, 'sha256': digest, 'retained_rows': backup_rows(good)})
    start(injected=True)
    log = (data / 'server.log').read_text()
    records.append({'fault_injected_server_log': log})
    assert 'Database backup failed' in log and ('SQLite error 13' in log or 'database or disk is full' in log)
    assert good.exists() and hashlib.sha256(good.read_bytes()).hexdigest() == digest
    assert backup_rows(good) == [('retained-proof-network',)]
    assert list((data / 'backups').glob('*.backup-pending')) == []
    candidates = sorted((data / 'backups').glob('db-*.sqlite'))
    assert all(path.stat().st_size > 0 and backup_rows(path) for path in candidates)
    stop()
    for suffix in ['-wal', '-shm']:
        pathlib.Path(str(data / 'db.sqlite') + suffix).unlink(missing_ok=True)
    (data / 'db.sqlite').write_bytes(b'corrupt active disposable database')
    invalid = data / 'backups' / 'db-2099-01-01T00-00-00Z.sqlite'
    invalid.write_bytes(b'')
    records.append({'recovery_setup': 'corrupted only disposable database; placed newer empty backup', 'known_good': good.name})
    start()
    rows = request('GET', '/networks')
    assert any(row['name'] == 'retained-proof-network' for row in rows)
    records.append({'recovered_marker': True, 'server_log': (data / 'server.log').read_text()})
    stop()
    records.append({'verdict': 'PASS', 'revision': revision})
finally:
    if meta:
        try:
            stop()
        except Exception as error:
            records.append({'stop_error': str(error)})
    alive = []
    for process in pathlib.Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            values = (process / 'environ').read_bytes().split(b'\0')
            raw = (process / 'cmdline').read_bytes()
            if ('BARKVISOR_DATA_DIR=' + str(data)).encode() in values and raw.split(b'\0')[0].split(b'/')[-1] == b'BarkVisorApp':
                pid = int(process.name)
                os.kill(pid, signal.SIGKILL)
                records.append({'forced_owned_cleanup_pid': pid})
                for _ in range(50):
                    try:
                        if (process / 'stat').read_text().split()[2] == 'Z':
                            break
                    except FileNotFoundError:
                        break
                    time.sleep(0.1)
                else:
                    alive.append(pid)
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass
    records.append({'teardown': 'PASS' if not alive else 'FAIL', 'remaining_owned_daemons': alive})
    (output / 'transcript.json').write_text(json.dumps(records, indent=2) + '\n')
    if not alive:
        shutil.rmtree(data, ignore_errors=True)
        shutil.rmtree(registry, ignore_errors=True)
        shutil.rmtree(sockets)
    assert not alive, alive
print(json.dumps({'verdict': 'PASS', 'transcript': str(output / 'transcript.json')}))
