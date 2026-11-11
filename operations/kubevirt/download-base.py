"""Stage the official Oracle Linux image using validated parallel byte ranges."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import time
import urllib.request

url = 'https://yum.oracle.com/templates/OracleLinux/OL9/u7/x86_64/OL9U7_x86_64-kvm-b269.qcow2'
root = Path('/home/hkl/sdm-kubevirt/cache')
root.mkdir(mode=0o700, exist_ok=True)
target = root / 'OL9U7_x86_64-kvm-b269.qcow2'
expected = '88c75cf913a66227e9ce74b0087ecac4cce1883f3e5649082e982d0d00310f1c'
if target.exists():
    digest = hashlib.sha256()
    with target.open('rb') as file:
        for data in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(data)
    if digest.hexdigest() != expected:
        raise RuntimeError('Existing cached image checksum does not match the verified lab image')
    print('Verified Oracle image is already cached.')
    raise SystemExit(0)
with urllib.request.urlopen(urllib.request.Request(url, method='HEAD'), timeout=30) as response:
    size = int(response.headers['Content-Length'])
    etag = response.headers.get('ETag')
partial = target.with_suffix('.partial')
fd = os.open(partial, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
os.ftruncate(fd, size)
chunk = 4 * 1024 * 1024


def download(start):
    end = min(start + chunk, size) - 1
    for attempt in range(5):
        try:
            headers = {'Range': 'bytes=%d-%d' % (start, end)}
            if etag:
                headers['If-Match'] = etag
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=90) as response:
                if response.status != 206 or response.headers.get('Content-Range') != 'bytes %d-%d/%d' % (start, end, size):
                    raise RuntimeError('Invalid byte-range response')
                data = response.read(end - start + 2)
            if len(data) != end - start + 1:
                raise RuntimeError('Truncated or oversized byte range')
            offset = start
            while data:
                count = os.pwrite(fd, data, offset)
                offset += count
                data = data[count:]
            return end - start + 1
        except Exception:
            if attempt == 4:
                raise
            time.sleep(2)


try:
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        futures = [pool.submit(download, start) for start in range(0, size, chunk)]
        for index, future in enumerate(concurrent.futures.as_completed(futures)):
            done += future.result()
            if index % 8 == 0:
                print('Oracle image download: %.1f%%' % (100 * done / size), flush=True)
    os.fsync(fd)
finally:
    os.close(fd)
digest = hashlib.sha256()
with partial.open('rb') as file:
    for data in iter(lambda: file.read(1024 * 1024), b''):
        digest.update(data)
if digest.hexdigest() != expected:
    raise RuntimeError('Downloaded image differs from the previously verified lab image; review before using it')
partial.rename(target)
target.with_suffix('.source.json').write_text(json.dumps({'url': url, 'bytes': size, 'etag': etag, 'sha256': digest.hexdigest()}, indent=2))
print('Official Oracle image staged; SHA256:', digest.hexdigest(), flush=True)
