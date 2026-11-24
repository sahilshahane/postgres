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

--reload "guc = val" (repeatable): after startup, ALTER SYSTEM SET + reload,
i.e. the setting changes at runtime rather than being set at server start
(regression test: wal_sync_method reloaded from fdatasync to open_datasync).

usage: crash.py INSTALLDIR WORKDIR PORT EPOCHS [--chaos] [--reload "guc = val"]...
                [guc = val ...]
"""
import os, random, signal, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pgtest import *

a = sys.argv[1:]
chaos_on = "--chaos" in a
a = [x for x in a if x != "--chaos"]
reload_gucs = []
while "--reload" in a:
    k = a.index("--reload")
    reload_gucs.append(a[k + 1])
    del a[k:k + 2]
inst, work, port, epochs = a[0], a[1], int(a[2]), int(a[3])
gucs = a[4:]
POWERCUT = os.environ.get("POWERCUT") == "1"
DEVSH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dev.sh")

if POWERCUT:
    # the device must be healthy: writes enabled, nothing else using it
    r = subprocess.run(["sudo", "-n", "-E", DEVSH, "check"], capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"power-cut device not ready (harness problem, not a test result): "
             f"{(r.stdout + r.stderr).strip()}")
pq = Libpq(inst)
datadir = os.environ.get("PGDATA_DIR") or os.path.join(work, "crash")
os.makedirs(work, exist_ok=True)
srv = Server(inst, datadir, port, pq)
# keep the server log off the power-cut device, or a cut would erase it
srv.log = os.path.join(work, "crash.log")
srv.initdb(["wal_io_method = aio", "wal_buffers = 64kB", "max_wal_size = 32MB",
            "min_wal_size = 4MB", "checkpoint_timeout = 30s",
            "max_connections = 40", "max_prepared_transactions = 40"] + gucs)
srv.start()
for kv in reload_gucs:
    g, _, v = kv.partition("=")
    srv.sql(f"ALTER SYSTEM SET {g.strip()} = '{v.strip()}'")
if reload_gucs:
    srv.sql("SELECT pg_reload_conf()")
    time.sleep(1)
    for kv in reload_gucs:
        g, _, v = kv.partition("=")
        now = srv.sql(f"SHOW {g.strip()}")
        if now != v.strip():
            fail(f"reload of {kv} did not take effect (SHOW says {now})")
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
        run("sudo", "-n", "-E", DEVSH, "powercut")
        srv.crash("all")
    else:
        srv.crash(kind)
    load.finish()
    chaos.finish()
    if kind == "powercut":
        r = subprocess.run(["sudo", "-n", "-E", DEVSH, "restore"], capture_output=True, text=True)
        if r.returncode != 0:
            fail(f"dev.sh restore failed (harness problem, not a test result): "
                 f"{(r.stdout + r.stderr).strip()}")
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
result(test="crash" + ("+chaos" if chaos_on else "") + ("+powercut" if POWERCUT else "")
       + "".join(f"+reload({kv})" for kv in reload_gucs),
       crashes=epochs, acked=total, lost=0, reloads=reloads, status="pass")
