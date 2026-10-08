import argparse
import json
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True)
args = parser.parse_args()
repo = pathlib.Path(__file__).resolve().parents[2]
output = pathlib.Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=False)
data = output / 'data'
registry = output / 'registry'
sockets = pathlib.Path(tempfile.mkdtemp(prefix='bv771-', dir='/tmp'))
name = 'dns-proof'
env = dict(os.environ, BARKVISOR_INSTANCE_DIR=str(registry), BARKVISOR_SOCKET_DIR=str(sockets), DOCKER_HOST='unix://' + str(output / 'no-docker.sock'))
meta = None
token = None
workload = None
records = []


def command(argv, timeout=60):
    result = subprocess.run(argv, cwd=repo, env=env, capture_output=True, text=True, timeout=timeout)
    records.append({'command': argv, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout


def request(method, path, body=None):
    headers = {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token}
    raw = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(meta['url'] + '/api' + path, method=method, data=raw, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            content = response.read()
            status = response.status
    except urllib.error.HTTPError as error:
        status = error.code
        content = error.read()
    result = json.loads(content) if content else None
    records.append({'method': method, 'path': path, 'request': body, 'status': status, 'response': result})
    return status, result


try:
    revision = command(['git', 'rev-parse', 'HEAD']).strip()
    command(['uname', '-a'])
    command(['swift', '--version'])
    command(['qemu-system-x86_64', '--version'])
    raw = command(['bash', 'scripts/dev-instance.sh', 'start', '--name', name, '--data-dir', str(data), '--skip-build'], timeout=120)
    meta = json.loads(raw)
    assert meta['port'] != 7777
    token = (registry / name / 'token').read_text().strip()
    records[-1]['stdout'] = json.dumps({k: meta[k] for k in ['name', 'url', 'port', 'agentPort', 'pid', 'dataDir']})
    for mode, dns in [('isolated', '8.8.8.8'), ('isolated', '10.0.2.2'), ('isolated', '10.0.2.15'), ('nat', '10.0.2.2'), ('nat', '10.0.2.15')]:
        status, result = request('POST', '/networks', {'name': mode + dns, 'mode': mode, 'dnsServer': dns})
        assert status == 400, (mode, dns, status, result)
    status, isolated = request('POST', '/networks', {'name': 'valid-private', 'mode': 'isolated', 'dnsServer': '10.0.2.3'})
    assert status == 200
    status, nat = request('POST', '/networks', {'name': 'valid-nat', 'mode': 'nat', 'dnsServer': '8.8.8.8'})
    assert status == 200
    status, result = request('PATCH', '/networks/' + nat['id'], {'mode': 'isolated'})
    assert status == 400
    status, rows = request('GET', '/networks')
    stored = next(row for row in rows if row['id'] == nat['id'])
    assert stored['mode'] == 'nat' and stored['dnsServer'] == '8.8.8.8'
    status, result = request('PATCH', '/networks/' + isolated['id'], {'dnsServer': '8.8.8.8'})
    assert status == 400
    status, disk = request('POST', '/disks', {'name': 'dns-proof-boot', 'sizeGB': 1, 'format': 'qcow2'})
    assert status == 200
    guest = 'linux-arm64' if os.uname().machine in ['aarch64', 'arm64'] else 'linux-x86_64'
    status, workload = request('POST', '/vms', {'name': 'dns-proof-vm', 'vmType': guest, 'cpuCount': 1, 'memoryMB': 128, 'existingDiskId': disk['id'], 'networkId': isolated['id'], 'uefi': False, 'tpmEnabled': False})
    assert status == 200
    status, result = request('POST', '/vms/' + workload['id'] + '/start', {})
    assert status == 204, result
    status, running = request('GET', '/vms/' + workload['id'])
    assert status == 200 and running['state'] == 'running'
    pid = int((data / 'pids' / (workload['id'] + '.pid')).read_text().splitlines()[0])
    argv = pathlib.Path('/proc', str(pid), 'cmdline').read_bytes().split(b'\0')
    netdev = argv[argv.index(b'-netdev') + 1].decode()
    assert netdev == 'user,id=net0,restrict=on,dns=10.0.2.3', netdev
    records.append({'owned_qemu_pid': pid, 'effective_netdev': netdev})
    status, result = request('POST', '/vms/' + workload['id'] + '/stop', {'force': True, 'method': 'force'})
    assert status == 204
    status, stopped = request('GET', '/vms/' + workload['id'])
    assert status == 200 and stopped['state'] == 'stopped'
    status, result = request('DELETE', '/vms/' + workload['id'])
    assert status == 202
    for _ in range(100):
        status, result = request('GET', '/vms/' + workload['id'])
        if status == 404:
            break
        time.sleep(0.1)
    assert status == 404
    workload = None
    for mode, dns, expected in [('isolated', '10.0.2.3', 0), ('nat', '8.8.8.8', 0), ('isolated', '8.8.8.8', 1), ('nat', '10.0.2.15', 1)]:
        netdev = 'user,id=net0' + (',restrict=on' if mode == 'isolated' else '') + ',dns=' + dns
        argv = ['qemu-system-x86_64', '-machine', 'none', '-nodefaults', '-display', 'none', '-m', '16', '-S', '-monitor', 'stdio', '-netdev', netdev]
        result = subprocess.run(argv, input='quit\n', capture_output=True, text=True, timeout=30)
        records.append({'command': argv, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
        assert result.returncode == expected
    records.append({'verdict': 'PASS', 'revision': revision})
finally:
    cleanup_errors = []
    if meta:
        if workload and token:
            try:
                request('POST', '/vms/' + workload['id'] + '/stop', {'force': True, 'method': 'force'})
            except Exception as error:
                cleanup_errors.append('API stop: ' + str(error))
        try:
            command(['bash', 'scripts/dev-instance.sh', 'stop', '--name', name, '--keep'], timeout=30)
        except Exception as error:
            cleanup_errors.append('Instance stop: ' + str(error))
    remaining = []
    for process in pathlib.Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            raw = (process / 'cmdline').read_bytes()
            executable = raw.split(b'\0')[0].split(b'/')[-1]
            owned_qemu = str(sockets).encode() in raw and executable.startswith(b'qemu-system')
            process_env = (process / 'environ').read_bytes().split(b'\0')
            owned_server = ('BARKVISOR_DATA_DIR=' + str(data)).encode() in process_env and executable == b'BarkVisorApp'
            if owned_qemu or owned_server:
                pid = int(process.name)
                os.kill(pid, signal.SIGKILL)
                records.append({'forced_owned_cleanup_pid': pid, 'identity': raw.replace(b'\0', b' ').decode()})
                for _ in range(50):
                    try:
                        state = (process / 'stat').read_text().split()[2]
                        if state == 'Z':
                            break
                    except FileNotFoundError:
                        break
                    time.sleep(0.1)
                else:
                    remaining.append(pid)
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass
    records.append({'teardown': 'PASS' if not remaining else 'FAIL', 'remaining_owned_processes': remaining, 'cleanup_errors': cleanup_errors})
    (output / 'transcript.json').write_text(json.dumps(records, indent=2) + '\n')
    if not remaining:
        shutil.rmtree(data, ignore_errors=True)
        shutil.rmtree(registry, ignore_errors=True)
        shutil.rmtree(sockets)
    assert not remaining, remaining
print(json.dumps({'verdict': 'PASS', 'transcript': str(output / 'transcript.json')}))
