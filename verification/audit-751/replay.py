import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True)
args = parser.parse_args()
repo = pathlib.Path(__file__).resolve().parents[2]
output = pathlib.Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=False)
assert os.geteuid() == 0
assert pathlib.Path('/proc/self/ns/net').readlink() != pathlib.Path('/proc/1/ns/net').readlink()
records = []
data = output / 'data'
registry = output / 'registry'
sockets = pathlib.Path(tempfile.mkdtemp(prefix='bv751-', dir='/tmp'))
env = dict(os.environ, BARKVISOR_INSTANCE_DIR=str(registry), BARKVISOR_SOCKET_DIR=str(sockets), DOCKER_HOST='unix://' + str(output / 'no-docker.sock'))
meta = None


def command(argv):
    result = subprocess.run(argv, cwd=repo, env=env, capture_output=True, text=True, timeout=120)
    records.append({'command': argv, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout


def request(path, body=None):
    token = (registry / 'bridge-proof' / 'token').read_text().strip()
    req = urllib.request.Request(meta['url'] + '/api' + path, method='POST' if body is not None else 'GET', data=None if body is None else json.dumps(body).encode(), headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as response:
        value = json.loads(response.read())
        records.append({'path': path, 'request': body, 'status': response.status, 'response': value})
        return value


try:
    command(['git', 'rev-parse', 'HEAD'])
    command(['mount', '--make-rprivate', '/'])
    command(['mount', '-t', 'tmpfs', 'tmpfs', '/etc/systemd/network'])
    command(['mount', '-t', 'tmpfs', 'tmpfs', '/etc/qemu'])
    command(['mount', '-t', 'sysfs', 'sysfs', '/sys'])
    command(['ip', 'link', 'set', 'lo', 'up'])
    command(['ip', 'link', 'add', 'brproof', 'type', 'bridge'])
    command(['ip', 'link', 'add', 'portproof', 'type', 'dummy'])
    command(['ip', 'link', 'set', 'portproof', 'master', 'brproof'])
    command(['ip', 'link', 'set', 'brproof', 'up'])
    command(['ip', 'link', 'set', 'portproof', 'up'])
    files = {
        '/etc/systemd/network/10-admin-brproof.netdev': '[NetDev]\nName=brproof\nKind=bridge\n',
        '/etc/systemd/network/20-admin-brproof.network': '[Match]\nName=brproof\n[Network]\nDHCP=yes\n',
        '/etc/systemd/network/20-admin-portproof.network': '[Match]\nName=portproof\n[Network]\nBridge=brproof\n',
    }
    for path, body in files.items():
        pathlib.Path(path).write_text(body)
    before = {path: hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() for path in files}
    raw = command(['bash', 'scripts/dev-instance.sh', 'start', '--name', 'bridge-proof', '--data-dir', str(data), '--skip-build'])
    meta = json.loads(raw)
    records[-1]['stdout'] = json.dumps({k: meta[k] for k in ['name', 'url', 'port', 'agentPort', 'pid', 'dataDir']})
    interfaces = request('/system/interfaces')
    result = request('/system/bridges', {'action': 'delete', 'bridge': 'brproof', 'interface': 'portproof', 'confirm': True})
    assert result['success'] is False and result.get('applied') is not True, result
    assert 'marker' in result['message'].lower() or 'shared' in result['message'].lower(), result
    command(['ip', '-json', 'link', 'show', 'brproof'])
    port = json.loads(command(['ip', '-json', 'link', 'show', 'portproof']))[0]
    assert 'master' in port
    after = {path: hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() for path in files}
    assert before == after
    records.append({'persistence_hashes_unchanged': before, 'port_still_enslaved': True, 'verdict': 'PASS'})
finally:
    if meta:
        command(['bash', 'scripts/dev-instance.sh', 'stop', '--name', 'bridge-proof', '--keep'])
    (output / 'transcript.json').write_text(json.dumps(records, indent=2) + '\n')
    shutil.rmtree(data, ignore_errors=True)
    shutil.rmtree(registry, ignore_errors=True)
    shutil.rmtree(sockets, ignore_errors=True)
print(json.dumps({'verdict': 'PASS', 'transcript': str(output / 'transcript.json')}))
