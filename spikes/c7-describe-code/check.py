"""Score a C7 spike run against the hidden tests (rules in decision 14).

    python3 check.py results/run1.json [results/run2.json]

With two runs, also reports whether the replies are byte-identical.
"""
import ast
import json
import os
import statistics
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

RUNNER = r'''
import ast, contextlib, io, json, sys, traceback
sys.path.insert(0, sys.argv[3])
import hidden_tests
src = open(sys.argv[1]).read()
test = hidden_tests.TESTS[sys.argv[2]]

def verdict(ok, reason=""):
    print(json.dumps({"ok": ok, "reason": reason}))
    sys.exit(0)

tree = ast.parse(src)
defs = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
if not defs:
    verdict(False, "no top-level function")
if len(defs) > 1:
    called = set()
    for d in defs:
        for n in ast.walk(d):
            if isinstance(n, ast.Name) and n.id != d.name:
                called.add(n.id)
    roots = [d for d in defs if d.name not in called]
    if len(roots) != 1:
        verdict(False, "ambiguous: " + ", ".join(d.name for d in defs))
    target = roots[0].name
else:
    target = defs[0].name

ns = {"__name__": "solution"}
try:
    with contextlib.redirect_stdout(io.StringIO()):
        exec(compile(src, "solution.py", "exec"), ns)
except BaseException as e:
    verdict(False, "load: " + type(e).__name__ + ": " + str(e)[:120])
f = ns[target]

def out(*a):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        r = f(*a)
    return r, buf.getvalue().splitlines()

try:
    test(f, out)
except AssertionError as e:
    tb = traceback.extract_tb(e.__traceback__)[-1]
    verdict(False, "assert failed: " + (tb.line or "") + (" (" + str(e) + ")" if str(e) else ""))
except BaseException as e:
    tb = traceback.extract_tb(e.__traceback__)[-1]
    verdict(False, type(e).__name__ + ": " + str(e)[:100] + " at: " + (tb.line or ""))
verdict(True)
'''


def split_fence(reply):
    """Returns (code, had_fence, prose_outside)."""
    lines = reply.strip("\n").split("\n")
    fence_idx = [i for i, l in enumerate(lines) if l.strip().startswith("```")]
    if not fence_idx:
        return reply.strip("\n"), False, False
    start = fence_idx[0]
    end = fence_idx[1] if len(fence_idx) > 1 else len(lines)
    outside = lines[:start] + lines[end + 1:]
    code = "\n".join(lines[start + 1:end])
    return code, True, any(l.strip() for l in outside)


def score(path):
    rows = []
    for r in json.load(open(path)):
        row = {"id": r["id"], "seconds": r["seconds"], "reply": r.get("reply"),
               "fence": False, "prose": False, "empty": False, "refusal": False,
               "ok": False, "reason": ""}
        if r.get("error"):
            row["refusal"] = True
            row["reason"] = "model error: " + r.get("error")[:120]
            rows.append(row)
            continue
        if not (r.get("reply") or "").strip():
            row["empty"] = True
            row["reason"] = "empty reply"
            rows.append(row)
            continue
        code, fence, prose = split_fence(r["reply"])
        row["fence"] = fence
        try:
            ast.parse(code)
        except SyntaxError as e:
            prose = True
            row["reason"] = "does not parse: " + str(e)[:80]
        row["prose"] = prose
        if row["reason"]:
            rows.append(row)
            continue
        with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as fh:
            fh.write(code)
        try:
            p = subprocess.run([sys.executable, "-c", RUNNER, fh.name, r["id"], HERE],
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
            v = json.loads(p.stdout.strip().splitlines()[-1]) if p.stdout.strip() else \
                {"ok": False, "reason": "runner crashed: " + p.stderr.strip()[-120:]}
        except subprocess.TimeoutExpired:
            v = {"ok": False, "reason": "timed out (10 s)"}
        finally:
            os.unlink(fh.name)
        row["ok"], row["reason"] = v["ok"], v["reason"]
        rows.append(row)
    return rows


def report(label, rows):
    print(f"\n## {label}\n")
    print("| # | Task | Result | Latency | Fence | Prose | Why it failed |")
    print("|---|---|---|---|---|---|---|")
    for i, r in enumerate(rows, 1):
        print(f"| {i} | {r['id']} | {'pass' if r['ok'] else 'FAIL'} | {r['seconds']:.2f} s | "
              f"{'yes' if r['fence'] else ''} | {'yes' if r['prose'] else ''} | {r['reason'].replace('|', '/')} |")
    lat = [r["seconds"] for r in rows]
    print(f"\npassed {sum(r['ok'] for r in rows)}/{len(rows)} · median {statistics.median(lat):.2f} s · "
          f"min {min(lat):.2f} s · max {max(lat):.2f} s · fences {sum(r['fence'] for r in rows)} · "
          f"prose {sum(r['prose'] for r in rows)} · refusal/error {sum(r['refusal'] for r in rows)} · "
          f"empty {sum(r['empty'] for r in rows)}")


if __name__ == "__main__":
    runs = [(p, score(p)) for p in sys.argv[1:]]
    for p, rows in runs:
        report(os.path.basename(p), rows)
    if len(runs) == 2:
        a, b = runs[0][1], runs[1][1]
        same = [x["id"] for x, y in zip(a, b) if x["reply"] == y["reply"]]
        print(f"\nidentical replies across runs: {len(same)}/{len(a)}")
        diff = [x["id"] for x, y in zip(a, b) if x["reply"] != y["reply"]]
        if diff:
            print("differ: " + ", ".join(diff))
