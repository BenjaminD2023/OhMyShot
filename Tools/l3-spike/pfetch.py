"""pfetch.py URL DEST SIZE SHA256 [PARTS]: finish a download from huggingface.co with parallel Range requests,
keeping what DEST already holds as its first bytes, then check the SHA-256."""
import hashlib, os, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

url, dest, size, sha = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
parts = int(sys.argv[5]) if len(sys.argv) > 5 else 8
have = os.path.getsize(dest) if os.path.exists(dest) else 0
chunk = (size - have + parts - 1) // parts
ranges = [(have + i * chunk, min(size, have + (i + 1) * chunk) - 1) for i in range(parts)]
ranges = [r for r in ranges if r[0] <= r[1]]

def fetch(i, a, b):
    part = f"{dest}.part{i}"
    while True:
        got = os.path.getsize(part) if os.path.exists(part) else 0
        if a + got > b:
            return part
        req = urllib.request.Request(url, headers={"Range": f"bytes={a + got}-{b}", "User-Agent": "pfetch"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r, open(part, "ab") as f:
                while True:
                    buf = r.read(1 << 20)
                    if not buf:
                        break
                    f.write(buf)
        except Exception as e:
            print(f"part {i}: {type(e).__name__} {e}; retrying", flush=True)
            time.sleep(2)

t = time.time()
with ThreadPoolExecutor(len(ranges)) as ex:
    files = list(ex.map(lambda r: fetch(*r), [(i, a, b) for i, (a, b) in enumerate(ranges)]))
with open(dest, "ab") as out:
    for p in files:
        with open(p, "rb") as f:
            while buf := f.read(1 << 24):
                out.write(buf)
        os.remove(p)
h = hashlib.sha256()
with open(dest, "rb") as f:
    while buf := f.read(1 << 24):
        h.update(buf)
ok = os.path.getsize(dest) == size and h.hexdigest() == sha
print(f"{'ok' if ok else 'BAD'} {dest}: {(size - have) / 1e6:.0f} MB in {time.time() - t:.0f} s")
