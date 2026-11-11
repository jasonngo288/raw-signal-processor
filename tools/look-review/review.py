#!/usr/bin/env python3
"""Look review tool for the 2026 film-look set.

  python3 -I tools/look-review/review.py render [dirs...] [--long-edge 1600] [--looks a,b]
  python3 -I tools/look-review/review.py serve [--port 8765]
  python3 -I tools/look-review/review.py roll [--against saved/looks.json]   (roll-consistency table)

`render` calls `raw-bench looks` (the same Swift pipeline the app uses: base developed once, every look finished on
it) and writes bench-out/look-review/. `serve` opens a local page (127.0.0.1 only) with one row per photo:
Apple default, our base, then every look, each with its metrics and feedback controls. Feedback is saved to
bench-out/look-review/feedback.json, which the orchestrator reads to tune the looks. Standard library only; no
pixels are processed in Python. bench-out/ is git-ignored: renders and feedback are never committed.
"""
import argparse, html, json, os, subprocess, sys, time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "bench-out", "look-review")
BENCH = os.path.join(ROOT, ".build", "release", "raw-bench")
FEEDBACK = os.path.join(OUT, "feedback.json")
TAGS = ["too warm", "too cool", "too green", "too magenta", "too contrasty", "too flat", "too saturated", "too muted",
        "skin wrong", "blacks lifted", "blacks crushed", "highlights clipped", "grain too strong", "grain too weak",
        "halation too strong", "banding", "love it"]


def render(args):
    dirs = args.dirs or [os.path.join(ROOT, "originals"), os.path.join(ROOT, "corpus-cache")]
    if not os.path.exists(BENCH) or args.build:
        subprocess.run(["swift", "build", "-c", "release"], cwd=ROOT, check=True)
    cmd = [BENCH, "looks", *dirs, "--out", OUT, "--long-edge", str(args.long_edge),
           "--manifest", os.path.join(ROOT, "corpus", "corpus.json")]
    if args.looks:
        cmd += ["--looks", args.looks]
    t = time.time()
    subprocess.run(cmd, cwd=ROOT, check=True)
    print(f"rendered in {time.time() - t:.0f} s → {OUT}; now: python3 -I tools/look-review/review.py serve")


def load_feedback():
    try:
        with open(FEEDBACK) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"items": {}, "looks": {}}


def page():
    with open(os.path.join(OUT, "looks.json")) as f:
        run = json.load(f)
    fb = load_feedback()
    rows = {}
    for r in run["rows"]:
        rows.setdefault(r["file"], []).append(r)
    def metrics(r):
        skin = r.get("skinHueShift")
        bits = [f"clip {r['clippedPercent']:.2f}%", f"p1 {r['blackP1']:.4f}", f"ΔE {r['deltaE00VsBase']:.1f}",
                f"chroma ×{r['chromaRatioVsBase']:.2f}"]
        if skin is not None:
            bits.append(f"skin {skin:+.1f}°")
        return " · ".join(bits)
    def warn(r, base):
        w = []
        if r["look"] not in ("apple", "base", "flashDigicam") and r["clippedPercent"] > max(base["clippedPercent"], 0.05) + 0.5:
            w.append("clips more than base")
        if r.get("skinHueShift") is not None and abs(r["skinHueShift"]) > 8:
            w.append("skin hue > 8°")
        return w
    out = []
    for file, rs in rows.items():
        base = next(r for r in rs if r["look"] == "base")
        e = rs[0]
        cards = []
        for r in rs:
            key = f"{file}|{r['look']}"
            f = fb["items"].get(key, {})
            vote = f.get("vote", "")
            tags = "".join(f'<label><input type="checkbox" data-tag="{t}" {"checked" if t in f.get("tags", []) else ""}>{t}</label>'
                           for t in TAGS)
            warns = "".join(f'<span class="warn">{w}</span>' for w in warn(r, base))
            ctl = "" if r["look"] in ("apple", "base") else f'''
              <div class="ctl" data-key="{html.escape(key)}">
                <button class="v up {'on' if vote == 'up' else ''}" data-v="up">👍</button>
                <button class="v down {'on' if vote == 'down' else ''}" data-v="down">👎</button>
                <details><summary>tags</summary><div class="tags">{tags}</div></details>
                <textarea placeholder="note">{html.escape(f.get('note', ''))}</textarea>
                <span class="saved"></span>
              </div>'''
            cards.append(f'''<figure><a href="{r['image']}" target="_blank"><img loading="lazy" src="{r['image']}"></a>
              <figcaption><b>{r['look']}</b><br><small>{metrics(r)}</small>{warns}</figcaption>{ctl}</figure>''')
        out.append(f'''<section><h2>{html.escape(e.get('id') or '')} {html.escape(file)}
          <small>{html.escape(e.get('category') or '')} {html.escape(e.get('split') or '')}</small></h2>
          <div class="grid">{''.join(cards)}</div></section>''')
    look_notes = "".join(f'''<div class="lk ctl" data-key="look|{l}"><b>{l}</b>
        <textarea placeholder="overall note for {l}">{html.escape(fb['looks'].get(l, {}).get('note', ''))}</textarea><span class="saved"></span></div>'''
                         for l in run["looks"])
    return f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Look Review</title><style>
:root{{--bg:#f6f4ef;--fg:#1d1b18;--mut:#6b665d;--card:#fff;--line:#e2ddd3;--acc:#b7791f;--bad:#b33}}
@media (prefers-color-scheme:dark){{:root{{--bg:#141311;--fg:#ece8e1;--mut:#9c968c;--card:#1e1c19;--line:#2e2b27;--acc:#e0a64a;--bad:#e66}}}}
body{{margin:0;background:var(--bg);color:var(--fg);font:13px/1.4 -apple-system,system-ui,sans-serif}}
header{{position:sticky;top:0;z-index:2;background:var(--bg);border-bottom:1px solid var(--line);padding:8px 16px}}
h1{{font-size:16px;margin:0}} h2{{font-size:14px;margin:0 0 6px}} h2 small,figcaption small{{color:var(--mut)}}
section{{padding:12px 16px;border-bottom:1px solid var(--line)}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:8px}}
figure{{margin:0;background:var(--card);border:1px solid var(--line);border-radius:6px;overflow:hidden}}
img{{display:block;width:100%;height:170px;object-fit:cover}} figcaption{{padding:4px 6px}}
.warn{{display:block;color:var(--bad);font-size:11px}} .ctl{{padding:4px 6px 6px}}
.v{{border:1px solid var(--line);background:none;border-radius:4px;cursor:pointer;padding:2px 8px}} .v.on{{background:var(--acc)}}
textarea{{width:100%;box-sizing:border-box;min-height:34px;margin-top:4px;background:var(--bg);color:var(--fg);border:1px solid var(--line);border-radius:4px}}
.tags{{display:flex;flex-wrap:wrap;gap:2px 8px;font-size:11px}} .saved{{color:var(--mut);font-size:11px}}
.looks{{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:8px;padding:8px 16px}}
</style></head><body><header><h1>Look review — {len(rows)} photos × {len(run['looks'])} looks</h1>
<small>Rendered {run['created']} at {run['longEdge']} px by raw-bench (same pipeline as the app). Feedback saves automatically to bench-out/look-review/feedback.json.</small>
</header><details open><summary style="padding:8px 16px">Overall notes per look</summary><div class="looks">{look_notes}</div></details>
{''.join(out)}
<script>
function save(ctl){{
  const key=ctl.dataset.key, up=ctl.querySelector('.v.up'), down=ctl.querySelector('.v.down');
  const body={{key, note:ctl.querySelector('textarea').value,
    vote: up&&up.classList.contains('on')?'up':(down&&down.classList.contains('on')?'down':''),
    tags:[...ctl.querySelectorAll('input[data-tag]:checked')].map(i=>i.dataset.tag)}};
  fetch('/feedback',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify(body)}})
    .then(r=>{{ctl.querySelector('.saved').textContent=r.ok?'saved':'save failed'}})
    .catch(()=>{{ctl.querySelector('.saved').textContent='save failed'}});
}}
document.querySelectorAll('.ctl').forEach(ctl=>{{
  ctl.querySelectorAll('.v').forEach(b=>b.addEventListener('click',()=>{{
    const on=!b.classList.contains('on'); ctl.querySelectorAll('.v').forEach(x=>x.classList.remove('on'));
    if(on) b.classList.add('on'); save(ctl);}}));
  ctl.querySelectorAll('input[data-tag]').forEach(i=>i.addEventListener('change',()=>save(ctl)));
  const t=ctl.querySelector('textarea'); let timer; t.addEventListener('input',()=>{{clearTimeout(timer);timer=setTimeout(()=>save(ctl),600)}});
}});
</script></body></html>'''


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=OUT, **k)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            body = page().encode()
            self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            super().do_GET()

    def do_POST(self):
        if self.path != "/feedback":
            self.send_error(404); return
        n = int(self.headers.get("Content-Length", 0))
        if n <= 0 or n > 100_000:
            self.send_error(400); return
        try:
            item = json.loads(self.rfile.read(n))
            key = str(item["key"])
        except (ValueError, KeyError):
            self.send_error(400); return
        fb = load_feedback()
        entry = {"note": str(item.get("note", ""))[:4000], "vote": item.get("vote") if item.get("vote") in ("up", "down") else "",
                 "tags": [t for t in item.get("tags", []) if t in TAGS], "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
        if key.startswith("look|"):
            fb["looks"][key[5:]] = entry
        else:
            fb["items"][key] = entry
        tmp = FEEDBACK + ".tmp"
        with open(tmp, "w") as f:
            json.dump(fb, f, indent=2, ensure_ascii=False)
        os.replace(tmp, FEEDBACK)
        self.send_response(204); self.end_headers()

    def log_message(self, *a):
        pass


def serve(args):
    if not os.path.exists(os.path.join(OUT, "looks.json")):
        sys.exit("no renders yet: run `review.py render` first")
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"look review: http://127.0.0.1:{args.port}/   (Ctrl+C to stop; feedback → {FEEDBACK})")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


def roll(args):
    """Roll consistency: a look develops a whole roll (24/36 frames), so its effect should be uniform across frames.
    Per look, over the tuning files (holdout skipped): brightness change vs base (mean, min, max, spread, and the slope
    vs base brightness: < 0 means bright frames are darkened more), chroma-ratio spread, worst clip / black-p1 rise,
    and look strength (ΔE vs base) spread. With --against, prints the deltas vs a saved looks.json."""
    def load(path):
        with open(path) as f:
            run = json.load(f)
        base = {r["file"]: r for r in run["rows"] if r["look"] == "base" and r.get("split") != "holdout"}
        out = {}
        for r in run["rows"]:
            b = base.get(r["file"])
            if b is None or r["look"] in ("base", "apple"):
                continue
            out.setdefault(r["look"], []).append((b, r))
        stats = {}
        for look, pairs in out.items():
            dy = [100 * (r["meanY"] / max(b["meanY"], 1e-6) - 1) for b, r in pairs]
            by = [b["meanY"] for b, _ in pairs]
            n = len(dy); mx = sum(by) / n; my = sum(dy) / n
            var = sum((x - mx) ** 2 for x in by)
            slope = sum((x - mx) * (y - my) for x, y in zip(by, dy)) / var if var > 0 else 0.0
            cr = [r["chromaRatioVsBase"] for _, r in pairs]
            de = [r["deltaE00VsBase"] for _, r in pairs]
            stats[look] = {"n": n, "dY_mean": my, "dY_min": min(dy), "dY_max": max(dy), "dY_spread": max(dy) - min(dy),
                           "dY_slope": slope / 10,   # % change per +0.1 base mean Y
                           "chroma_spread": max(cr) - min(cr),
                           "clip_rise_max": max(r["clippedPercent"] - b["clippedPercent"] for b, r in pairs),
                           "p1_rise_max": max(r["blackP1"] - b["blackP1"] for b, r in pairs),
                           "dE_mean": sum(de) / n, "dE_spread": max(de) - min(de)}
        return stats
    cur = load(os.path.join(OUT, "looks.json"))
    ref = load(args.against) if args.against else None
    cols = ["dY_mean", "dY_min", "dY_max", "dY_spread", "dY_slope", "chroma_spread", "clip_rise_max", "p1_rise_max", "dE_mean", "dE_spread"]
    print("look".ljust(16) + " n " + "".join(c.rjust(14) for c in cols))
    for look in sorted(cur):
        st = cur[look]
        line = look.ljust(16) + f"{st['n']:2d} " + "".join(f"{st[c]:14.3f}" for c in cols)
        print(line)
        if ref and look in ref:
            print("  Δ vs ref".ljust(19) + "".join(f"{st[c] - ref[look][c]:+14.3f}" for c in cols))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render"); r.add_argument("dirs", nargs="*"); r.add_argument("--long-edge", type=int, default=1600)
    r.add_argument("--looks"); r.add_argument("--build", action="store_true")
    s = sub.add_parser("serve"); s.add_argument("--port", type=int, default=8777)
    c = sub.add_parser("roll"); c.add_argument("--against", help="a saved looks.json to compare with")
    a = p.parse_args()
    {"render": render, "serve": serve, "roll": roll}[a.cmd](a)


if __name__ == "__main__":
    main()
