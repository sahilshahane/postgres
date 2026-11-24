#!/usr/bin/env python3
"""PostgreSQL's own regression and isolation suites against a server that
writes WAL with AIO (meson's "running" test setup).

usage: regress.py BUILDDIR INSTALLDIR WORKDIR PORT [guc = val ...]
With no GUCs, wal_io_method stays 'sync': the stock baseline, to tell
failures caused by AIO from failures of the environment.
"""
import os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pgtest import *

build, inst, work, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
gucs = sys.argv[5:]
pq = Libpq(inst)
os.makedirs(work, exist_ok=True)
srv = Server(inst, os.path.join(work, "regress"), port, pq)
srv.initdb((["wal_io_method = aio"] if gucs else []) + gucs +
           ["max_connections = 100", "max_prepared_transactions = 10"])
srv.start()
# pg_regress / isolationtester run psql from PATH: it must be this build's,
# not the system's (an older psql gives spurious diffs and hangs)
env = dict(os.environ, PGHOST="/tmp", PGPORT=str(port),
           PATH=os.path.join(inst, "bin") + os.pathsep + os.environ["PATH"])
r = subprocess.run(["meson", "test", "-C", build, "--setup", "running", "--no-rebuild",
                    "--suite", "regress-running", "--suite", "isolation-running",
                    "--print-errorlogs"], env=env, capture_output=True, text=True)
srv.stop()
out = r.stdout + r.stderr
open(os.path.join(work, "regress.out"), "w").write(out)
def count(name):
    m = re.search(rf"^{name}:\s+(\d+)", out, re.M)
    return int(m.group(1)) if m else -1
ok, bad, tmo = count("Ok"), count("Fail"), count("Timeout")
problems = srv.log_problems()
# per suite: "... OK  41.68s   134 subtests passed" / "... FAIL ... 3/222 subtests failed"
passed = sum(int(x) for x in re.findall(r"(\d+) subtests passed", out))
failed_sub = sum(int(x) for x in re.findall(r"(\d+)/\d+ subtests failed", out))
if problems:
    print("\n".join(problems[:20]))
status = "pass" if bad == 0 and tmo == 0 and ok > 0 and not problems else "FAIL"
if status != "pass":
    print(f"FAIL: see {work}/regress.out and {srv.log}")
    for line in out.splitlines():
        if re.search(r"FAIL|TIMEOUT", line):
            print(line)
result(test="regress", suites_ok=ok, suites_failed=bad, suites_timeout=tmo,
       subtests_passed=passed, subtests_failed=failed_sub, status=status)
sys.exit(0 if status == "pass" else 1)
