#!/usr/bin/env python3
"""Run the correctness suite for every mode in modes.txt and append one row
per (mode, test) to a CSV.

usage: run_all.py --inst INSTALLDIR --work WORKDIR --out results.csv
                  [--build BUILDDIR]      (needed for the regress test)
                  [--tests regress,crash,chaos,repl] [--modes a,b,...]
                  [--epochs 8] [--port 59400] [--label text]
Each test runs in its own process; its output goes to WORKDIR/<mode>/<test>.test.txt.
POWERCUT=1 in the environment turns the crash tests into power-cut tests
(root, dev.sh device; see crash.py).
"""
import argparse, csv, datetime, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from pgtest import read_modes

ap = argparse.ArgumentParser()
ap.add_argument("--inst", required=True)
ap.add_argument("--work", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--build")
ap.add_argument("--tests", default="regress,crash,chaos,repl")
ap.add_argument("--modes")
ap.add_argument("--epochs", type=int, default=8)
ap.add_argument("--port", type=int, default=59400)
ap.add_argument("--label", default="")
o = ap.parse_args()

modes = read_modes()
names = o.modes.split(",") if o.modes else list(modes)
tests = o.tests.split(",")
if "regress" in tests:
    if not o.build:
        sys.exit("--build is required for the regress test")
    names = ["stock"] + names          # baseline: same suites, wal_io_method = sync
    modes["stock"] = []

new = not os.path.exists(o.out)
out = open(o.out, "a", newline="")
cols = ["date", "label", "mode", "test", "status", "seconds", "detail", "settings"]
wr = csv.DictWriter(out, fieldnames=cols)
if new:
    wr.writeheader()
failures = 0
for m in names:
    for t in tests:
        if m == "stock" and t != "regress":
            continue
        work = os.path.join(o.work, m)
        os.makedirs(work, exist_ok=True)
        py = [sys.executable, "-u"]
        if t == "regress":
            cmd = py + [f"{HERE}/regress.py", o.build, o.inst, work, str(o.port)]
        elif t in ("crash", "chaos"):
            cmd = py + [f"{HERE}/crash.py", o.inst, work, str(o.port), str(o.epochs)]
            if t == "chaos":
                cmd.append("--chaos")
        elif t == "repl":
            cmd = py + [f"{HERE}/repl.py", o.inst, work, str(o.port)]
        else:
            sys.exit(f"unknown test {t}")
        cmd += modes[m]
        log = os.path.join(work, f"{t}.test.txt")
        t0 = time.time()
        with open(log, "w") as f:
            try:
                rc = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT,
                                    timeout=1800).returncode
            except subprocess.TimeoutExpired:
                rc = "timeout"
        secs = round(time.time() - t0)
        lines = open(log, errors="replace").read().splitlines()
        res = [l for l in lines if l.startswith("RESULT ")]
        fails = [l for l in lines if l.startswith("FAIL")]
        if rc == 0 and res:
            status, detail = "pass", res[-1][7:]
        else:
            status = "FAIL"
            detail = (fails[-1] if fails else f"exit {rc}, see {log}")[:300]
            failures += 1
        wr.writerow(dict(date=datetime.datetime.now().isoformat(timespec="seconds"),
                         label=o.label, mode=m, test=t, status=status, seconds=secs,
                         detail=detail, settings="; ".join(modes[m])))
        out.flush()
        print(f"{m:28s} {t:8s} {status:5s} {secs:4d}s  {detail}", flush=True)
        # don't leave data directories around (disk space); keep them for a failure
        if status == "pass":
            subprocess.run(["rm", "-rf"] + [os.path.join(work, d) for d in
                           ("crash", "primary", "standby", "regress", "archive")])
print(f"{'ALL PASSED' if failures == 0 else f'{failures} FAILED'}; results in {o.out}")
sys.exit(1 if failures else 0)
