#!/usr/bin/env python3
"""Crash test: no acknowledged commit may be lost.

Each epoch: 16 clients commit (small, large, async, two-phase), optionally
while the AIO GUCs are reloaded at random ("chaos"), then the server is
crashed at a random moment, restarted (crash recovery) and checked:
every acknowledged commit present in full, heap and index consistent
(amcheck), no PANIC/assertion failure in the log.  Crash kinds rotate:
  all         SIGSTOP + SIGKILL every process (OS crash)
  postmaster  SIGKILL the postmaster only; children must exit by themselves
  powercut    (POWERCUT=1, needs root, data dir on the dev.sh device) the
              disk drops every write from this moment, page cache is lost

usage: crash.py INSTALLDIR WORKDIR PORT EPOCHS [--chaos] [guc = val ...]
"""
import os, random, signal, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pgtest import *

a = sys.argv[1:]
chaos_on = "--chaos" in a
a = [x for x in a if x != "--chaos"]
inst, work, port, epochs = a[0], a[1], int(a[2]), int(a[3])
gucs = a[4:]
POWERCUT = os.environ.get("POWERCUT") == "1"
DEVSH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dev.sh")

pq = Libpq(inst)
datadir = os.environ.get("PGDATA_DIR") or os.path.join(work, "crash")
os.makedirs(work, exist_ok=True)
srv = Server(inst, datadir, port, pq)
srv.initdb(["wal_io_method = aio", "wal_buffers = 64kB", "max_wal_size = 32MB",
            "min_wal_size = 4MB", "checkpoint_timeout = 30s",
            "max_connections = 40", "max_prepared_transactions = 40"] + gucs)
srv.start()
srv.sql(TABLE_DDL)
srv.sql("CHECKPOINT")
os.sync()

total, reloads, kinds = 0, 0, []
for epoch in range(1, epochs + 1):
    kind = "powercut" if POWERCUT else ("all" if epoch % 2 else "postmaster")
    load = Load(pq, port, epoch)
    chaos = Chaos(pq, port, enabled=chaos_on)
    time.sleep(random.uniform(0.3, 3.0))
    if kind == "powercut":
        os.kill(srv.proc.pid, signal.SIGSTOP)
        for pid in srv.children():
            os.kill(pid, signal.SIGSTOP)
        run("sudo", "-E", DEVSH, "powercut")
        srv.crash("all")
    else:
        srv.crash(kind)
    load.finish()
    chaos.finish()
    if kind == "powercut":
        run("sudo", "-E", DEVSH, "restore")
    srv.start()
    n = load.verify(srv)
    amcheck(srv)
    if chaos_on:
        reloads += chaos.reloads
        reset_chaos(srv)
    total += n
    kinds.append(kind)
    print(f"epoch {epoch} ({kind}{', chaos %d reloads' % chaos.reloads if chaos_on else ''}): "
          f"{n} acknowledged commits present", flush=True)

srv.stop()
bad = srv.log_problems()
# a crash test's log legitimately has "terminating ... because of crash" lines;
# PANIC/TRAP are never expected
if bad:
    fail("server log:\n" + "\n".join(bad[:20]))
result(test="crash" + ("+chaos" if chaos_on else "") + ("+powercut" if POWERCUT else ""),
       crashes=epochs, acked=total, lost=0, reloads=reloads, status="pass")
