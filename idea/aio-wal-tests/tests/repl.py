#!/usr/bin/env python3
"""Replication, archiving and promotion with AIO WAL.

The walsender only sends WAL up to the Flush pointer, so if AIO ever let
Flush pass a write that was still in flight, a standby could receive WAL
that the primary then loses in a crash.  Steps:

 1. Primary (archive_mode on, 1 MB segments, small wal_buffers) + streaming
    standby from pg_basebackup.  Load with chaos (random reloads of the AIO
    GUCs), sampling pg_aios for concurrent WAL IO.
 2. Crash the primary (SIGKILL all), restart it, load a bit more.  The
    standby must reconnect without "ahead of the WAL flush position" errors,
    catch up, and have exactly the primary's contents.
 3. Archive: every segment archived, no gaps, pg_waldump parses all of it
    (across the crash).
 4. Promote the standby (now writing WAL with AIO on a new timeline), load,
    crash it, restart: every acknowledged commit present, amcheck clean.
 5. Single-user mode with wal_io_method = aio (AIO is not used there) can
    write and checkpoint; the server starts normally afterwards.

usage: repl.py INSTALLDIR WORKDIR PORT [guc = val ...]   (uses PORT, PORT+1)
"""
import os, random, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pgtest import *

inst, work, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
gucs = sys.argv[4:]
pq = Libpq(inst)
os.makedirs(work, exist_ok=True)
arch = os.path.join(work, "archive")
subprocess.run(["rm", "-rf", arch], check=True)
os.makedirs(arch)
common = ["wal_io_method = aio", "wal_buffers = 64kB", "max_wal_size = 32MB",
          "min_wal_size = 4MB", "max_connections = 40", "max_prepared_transactions = 40",
          "wal_level = replica", "max_wal_senders = 4", "hot_standby = on"] + gucs

pri = Server(inst, os.path.join(work, "primary"), port, pq)
pri.initdb(common + ["archive_mode = on",
                     f"archive_command = 'test ! -f {arch}/%f && cp %p {arch}/%f'"])
pri.start()
pri.sql(TABLE_DDL)

sby = Server(inst, os.path.join(work, "standby"), port + 1, pq)
subprocess.run(["rm", "-rf", sby.datadir, sby.log], check=True)
run(os.path.join(inst, "bin", "pg_basebackup"), "-h", "/tmp", "-p", str(port),
    "-D", sby.datadir, "-R", "-X", "stream", "-c", "fast")
with open(os.path.join(sby.datadir, "postgresql.conf"), "a") as f:
    f.write(f"\nport = {port + 1}\narchive_mode = off\n")
sby.start()


def sample_inflight(srv, seconds):
    """Max number of WAL IOs in flight seen in pg_aios."""
    best, end = 0, time.time() + seconds
    c = pq.connect(srv.port)
    while c and time.time() < end:
        r = pq.execute(c, "SELECT count(*) FROM pg_aios WHERE target_desc LIKE '%WAL%' "
                          "AND state IN ('DEFINED','STAGED','SUBMITTED','COMPLETED_IO')")
        if r is None:
            break
        best = max(best, int(r[0][0]))
        time.sleep(0.005)
    if c:
        pq.finish(c)
    return best


def wait_caught_up(timeout=120):
    target = pri.sql("SELECT pg_current_wal_lsn()")
    deadline = time.time() + timeout
    while time.time() < deadline:
        ok = sby.sql(f"SELECT pg_last_wal_replay_lsn() >= '{target}'::pg_lsn", check=False)
        if ok == "t":
            return
        time.sleep(0.2)
    fail(f"standby did not catch up to {target}; see {sby.log}")


def contents(srv):
    return srv.sql("SELECT count(*) || ':' || coalesce(md5(string_agg("
                   "epoch||','||w||','||i||','||j||','||pad, ';' ORDER BY epoch,w,i,j)),'') FROM t")


# 1. load with chaos, then crash the primary
load = Load(pq, port, 1)
chaos = Chaos(pq, port)
inflight = sample_inflight(pri, random.uniform(2.0, 4.0))
pri.crash("all")
load.finish(); chaos.finish()
received = sby.sql("SELECT pg_last_wal_receive_lsn()")

# 2. restart, more load, compare
pri.start()
acked = load.verify(pri)
reset_chaos(pri)
end_of_recovery = pri.sql("SELECT pg_current_wal_lsn()")
if pri.sql(f"SELECT '{received}'::pg_lsn > '{end_of_recovery}'::pg_lsn") == "t":
    fail(f"standby received WAL up to {received}, beyond what the primary "
         f"recovered ({end_of_recovery}): WAL was sent before it was durable")
load = Load(pq, port, 2, nworkers=8)
time.sleep(1.5)
load.finish()
acked += sum(len(x) for x in load.acked)
wait_caught_up()
cp, cs = contents(pri), contents(sby)
if cp != cs:
    fail(f"standby contents differ from primary: {cs} vs {cp}")

# 3. archive continuity + pg_waldump over everything archived
last = pri.sql("SELECT pg_walfile_name(pg_current_wal_lsn())")
pri.sql("SELECT pg_switch_wal()")
pri.sql("CHECKPOINT")
for _ in range(600):
    if os.path.exists(os.path.join(arch, last)):
        break
    time.sleep(0.1)
names = sorted(n for n in os.listdir(arch) if len(n) == 24)
nums = [int(n[8:16], 16) * 4096 + int(n[16:24], 16) for n in names]   # 1 MB segments
missing = sorted(set(range(nums[0], nums[-1] + 1)) - set(nums))
if missing:
    fail(f"archive has gaps: {len(missing)} segments missing")
w = subprocess.run([os.path.join(inst, "bin", "pg_waldump"), "-q", "-p", arch,
                    names[0], last], capture_output=True, text=True)
if w.returncode != 0:
    fail(f"pg_waldump over the archive failed: {w.stderr.strip()[:500]}")

# 4. promote the standby, load, crash it, recover
pri.stop()
run(os.path.join(inst, "bin", "pg_ctl"), "-D", sby.datadir, "-w", "promote")
load = Load(pq, port + 1, 3)
chaos = Chaos(pq, port + 1)
time.sleep(random.uniform(1.0, 3.0))
sby.crash("all")
load.finish(); chaos.finish()
sby.start()
acked += load.verify(sby)
amcheck(sby)
reset_chaos(sby)
sby.stop()

# 5. single-user mode with wal_io_method = aio
r = subprocess.run([os.path.join(inst, "bin", "postgres"), "--single", "-D", sby.datadir,
                    "postgres"], input="INSERT INTO t VALUES (9,0,0,0,'single');\nCHECKPOINT;\n",
                   capture_output=True, text=True, timeout=120)
if r.returncode != 0:
    fail(f"single-user mode failed: {r.stderr[-500:]}")
sby.start()
if sby.sql("SELECT count(*) FROM t WHERE epoch = 9") != "1":
    fail("row written in single-user mode is missing")
sby.stop()

bad = pri.log_problems() + sby.log_problems()
if bad:
    fail("server log:\n" + "\n".join(bad[:20]))
result(test="repl", acked=acked, max_inflight=inflight, segments=len(names),
       status="pass")
