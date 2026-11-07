#!/usr/bin/env python3
"""Download the public RAWs listed in corpus/corpus.json into a cache dir (CI only; never commit them).
Prints SHA-256 and size of every file so the manifest can be pinned later."""
import hashlib, json, os, sys, urllib.request

manifest, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
failed = 0
for f in json.load(open(manifest))["files"]:
    if f.get("location") != "corpus":
        continue
    dst = os.path.join(out, f["file"])
    if not os.path.exists(dst):
        try:
            req = urllib.request.Request(f["url"], headers={"User-Agent": "raw-signal-processor-ci"})
            with urllib.request.urlopen(req, timeout=180) as r, open(dst + ".part", "wb") as w:
                while chunk := r.read(1 << 20):
                    w.write(chunk)
            os.replace(dst + ".part", dst)
        except Exception as e:  # keep going: one missing file must not hide the rest
            print(f"FAIL {f['id']} {f['file']}: {e}")
            failed += 1
            continue
    h = hashlib.sha256(open(dst, "rb").read()).hexdigest()
    pinned = f.get("sha256")
    status = "ok" if not pinned or pinned == h else "HASH MISMATCH"
    print(f"{status} {f['id']} {f['file']} {os.path.getsize(dst)} bytes sha256={h}")
    if status != "ok":
        failed += 1
sys.exit(1 if failed else 0)
