"""Read-only guest checks. Run through sudo; never print credentials."""
from pathlib import Path
import json
import subprocess
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
props = dict(line.split('=', 1) for line in Path('/root/sdm-setup.properties').read_text().splitlines() if '=' in line and not line.startswith('#'))
session = requests.Session()
session.verify = False
session.headers['Accept'] = 'application/json'
base = 'https://127.0.0.1:8443/rest/v1.3'
assert session.get('https://127.0.0.1:8443/', timeout=10).status_code == 200
response = session.post(base + '/admin/login', json={'userName': 'admin', 'password': props['ADMIN_PASSWORD']}, timeout=30)
assert response.status_code == 200 and session.cookies
print('HTTPS and authenticated REST login: PASS')


def records(value):
    if isinstance(value, dict):
        if 'id' in value and 'packageName' in value:
            yield value
        else:
            for child in value.values():
                yield from records(child)
    elif isinstance(value, list):
        for child in value:
            yield from records(child)


try:
    response = session.get(base + '/admin/plugins', timeout=30)
    response.raise_for_status()
    plugins = list(records(response.json()))
    assert len(plugins) == 3
    for plugin in plugins:
        members = plugin.get('clusterMembers', plugin.get('pluginClusterMembers', []))
        members = [members] if isinstance(members, dict) else members
        statuses = [member.get('pluginStatus') for member in members]
        assert statuses and all(status in ('INSTALLED', 'LOADED') for status in statuses)
        print(plugin['name'], statuses)
finally:
    session.post(base + '/admin/logout', timeout=20)

for name in ('ent_edge_coreEMPlugin.jar', 'ent_utilitiesEMPlugin.jar', 'sp_edge_coreEMPlugin.jar'):
    matches = list(Path('/opt/AcmePacket/NNC90_5').rglob(name))
    assert matches and all(path.stat().st_size > 0 for path in matches)
    print(name, 'nonempty copies:', len(matches))
print('Boot ID:', Path('/proc/sys/kernel/random/boot_id').read_text().strip())
for command in (['systemctl', 'is-enabled', 'sdm'], ['systemctl', 'is-active', 'sdm'], ['getenforce']):
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    print(' '.join(command), result.stdout.strip())
sockets = subprocess.run(['ss', '-lntup'], capture_output=True, text=True, check=True).stdout
for line in sockets.splitlines():
    if ':8443' in line or ':162 ' in line:
        print(line)
assert any(':162 ' in line and '10.0.2.2' in line for line in sockets.splitlines())
print('Guest verification: PASS')
