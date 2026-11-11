"""Run as root inside the fresh SDM VM; credentials remain in the guest."""
import json
from pathlib import Path
import time
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
props = dict(line.split('=', 1) for line in Path('/root/sdm-setup.properties').read_text().splitlines() if '=' in line and not line.startswith('#'))
session = requests.Session()
session.verify = False  # Guest-local HTTPS endpoint uses its generated self-signed certificate.
session.headers['Accept'] = 'application/json'
base = 'https://127.0.0.1:8443/rest/v1.3'
response = session.post(base + '/admin/login', json={'userName': 'admin', 'password': props['ADMIN_PASSWORD']}, timeout=30)
if response.status_code != 200:
    raise RuntimeError('SDM login returned HTTP ' + str(response.status_code))
if not session.cookies:
    raise RuntimeError('SDM did not provide an authenticated session cookie')


def statuses(info):
    members = info.get('clusterMembers', info.get('pluginClusterMembers', []))
    if isinstance(members, dict):
        members = [members]
    return [m.get('pluginStatus', '') for m in members]


def plugin_records(value):
    if isinstance(value, dict):
        if 'id' in value and 'packageName' in value:
            yield value
        else:
            for child in value.values():
                yield from plugin_records(child)
    elif isinstance(value, list):
        for child in value:
            yield from plugin_records(child)


try:
    for filename in ['ent_edge_core22.0_Package.zip', 'ent_utilities22.0_Package.zip', 'sp_edge_core22.0_Package.zip']:
        response = session.get(base + '/admin/plugins', timeout=30)
        response.raise_for_status()
        info = next((p for p in plugin_records(response.json()) if p['packageName'] == filename), None)
        if info is None:
            with (Path('/home/hkl/sdm-media') / filename).open('rb') as file:
                response = session.post(base + '/admin/plugins', files={'file': (filename, file, 'application/zip')}, timeout=300)
            if not 200 <= response.status_code < 300:
                raise RuntimeError(filename + ' upload returned HTTP ' + str(response.status_code))
            info = response.json()
            if 'pluginInfo' in info:
                info = info['pluginInfo']
        plugin_id = info['id']
        print('Uploaded:', info.get('name'), plugin_id, flush=True)
        state = statuses(info)
        if state and all(s in ('INSTALLED', 'LOADED') for s in state):
            print('Already installed:', info.get('name'), state, flush=True)
            continue
        if any('FAIL' in s.upper() for s in state):
            raise RuntimeError('Existing plug-in needs diagnosis: ' + str(state))
        if not state or all(s == 'UPLOADED' for s in state):
            response = session.post(base + '/admin/plugins/' + plugin_id + '/action', json={'type': 'install'}, timeout=90)
            if not 200 <= response.status_code < 300:
                raise RuntimeError(filename + ' install returned HTTP ' + str(response.status_code))
        for attempt in range(90):
            response = session.get(base + '/admin/plugins/' + plugin_id, timeout=30)
            response.raise_for_status()
            info = response.json()
            info = info.get('pluginInfo', info)
            state = statuses(info)
            if attempt % 4 == 0:
                print(info.get('name'), state, flush=True)
            if any('FAIL' in s.upper() for s in state):
                raise RuntimeError('Plug-in installation failed: ' + str(state))
            if state and all(s in ('INSTALLED', 'LOADED') for s in state):
                print('Verified installed:', info.get('name'), state, flush=True)
                break
            time.sleep(5)
        else:
            raise RuntimeError('Plug-in status did not reach installed state')
    Path('/root/sdm-plugins-complete').touch()
finally:
    session.post(base + '/admin/logout', timeout=30)
