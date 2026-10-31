#!/usr/bin/env python3
"""
Crash test for wal_io_method = aio.

Repeatedly: run concurrent clients that commit transactions and remember
every commit the server acknowledged, SIGKILL the whole server (postmaster
and all children) at a random point, restart (crash recovery), and check
that every acknowledged commit is present and complete.

Usage: crash_test.py INSTALLDIR WORKDIR IO_METHOD ITERATIONS PORT [extra GUC=val ...]

  Odd iterations SIGKILL every server process (frozen first with SIGSTOP),
  even ones kill only the postmaster.  With POWERCUT=1 every iteration is a
  simulated power loss instead, using dev.sh; then set PGDATA_DIR to a
  directory on the test disk (e.g. $TESTDISK_DIR/mnt/data) and run
  "sudo -v" first.  Exits non-zero and prints FAIL if an acknowledged commit
  is missing after recovery.
"""
import ctypes, os, random, signal, subprocess, sys, threading, time

inst, work, io_method, iters, port = sys.argv[1:6]
iters, port = int(iters), int(port)
extra = sys.argv[6:]
bindir = os.path.join(inst, "bin")
# POWERCUT=1: simulate power loss using dev.sh (PGDATA must be on its device)
POWERCUT = os.environ.get("POWERCUT") == "1"
DEVSH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dev.sh")
pgdata = os.environ.get("PGDATA_DIR") or os.path.join(work, "data")
archive = os.path.join(work, "archive")
logfile = os.path.join(work, "server.log")

import glob
pq = ctypes.CDLL(sorted(glob.glob(os.path.join(inst, "lib", "**", "libpq.so*"),
                                  recursive=True))[0])
pq.PQconnectdb.restype = ctypes.c_void_p
pq.PQconnectdb.argtypes = [ctypes.c_char_p]
pq.PQstatus.argtypes = [ctypes.c_void_p]
pq.PQexec.restype = ctypes.c_void_p
pq.PQexec.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
pq.PQresultStatus.argtypes = [ctypes.c_void_p]
pq.PQclear.argtypes = [ctypes.c_void_p]
pq.PQfinish.argtypes = [ctypes.c_void_p]
pq.PQntuples.argtypes = [ctypes.c_void_p]
pq.PQgetvalue.restype = ctypes.c_char_p
pq.PQgetvalue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
pq.PQerrorMessage.restype = ctypes.c_char_p
pq.PQerrorMessage.argtypes = [ctypes.c_void_p]

CONNSTR = f"host=/tmp port={port} dbname=postgres".encode()
NWORKERS = 16
BIGROWS = 40


def connect():
    c = pq.PQconnectdb(CONNSTR)
    if pq.PQstatus(c) != 0:
        pq.PQfinish(c)
        return None
    return c


def execute(c, sql):
    """Returns list of rows (tuples of str) or None on failure."""
    r = pq.PQexec(c, sql.encode())
    st = pq.PQresultStatus(r) if r else -1
    if st not in (1, 2):  # PGRES_COMMAND_OK, PGRES_TUPLES_OK
        if r:
            pq.PQclear(r)
        return None
    rows = []
    if st == 2:
        n = pq.PQntuples(r)
        ncol = 1 if n == 0 else len(sql)  # unused
        for i in range(n):
            rows.append(pq.PQgetvalue(r, i, 0).decode())
    pq.PQclear(r)
    return rows


def query_rows(c, sql, ncols):
    r = pq.PQexec(c, sql.encode())
    assert pq.PQresultStatus(r) == 2, pq.PQerrorMessage(c)
    out = [tuple(pq.PQgetvalue(r, i, j).decode() for j in range(ncols))
           for i in range(pq.PQntuples(r))]
    pq.PQclear(r)
    return out


def run(*args, **kw):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, **kw)


def start_server():
    log = open(logfile, "a")
    p = subprocess.Popen([os.path.join(bindir, "postgres"), "-D", pgdata],
                         stdout=log, stderr=log, start_new_session=True)
    for _ in range(600):
        c = connect()
        if c:
            pq.PQfinish(c)
            return p
        if p.poll() is not None:
            sys.exit(f"server exited during startup, see {logfile}")
        time.sleep(0.05)
    sys.exit("server did not start")


def devsh(cmd):
    # needs root; run "sudo -v" before starting the test
    subprocess.run(["sudo", "-E", DEVSH, cmd], check=True, stdout=subprocess.DEVNULL)


def worker(epoch, w, acked, stop):
    c = connect()
    if not c:
        return
    i = 0
    while not stop.is_set():
        i += 1
        r = random.random()
        if r < 0.05:
            # async commit: no durability promise, don't record
            sql = (f"SET synchronous_commit = off; INSERT INTO t VALUES "
                   f"({epoch},{w},{i},0,'async'); RESET synchronous_commit")
            kind = None
        elif r < 0.20:
            # big transaction, spans many WAL pages
            sql = (f"INSERT INTO t SELECT {epoch},{w},{i},j,repeat(md5(j::text), 60) "
                   f"FROM generate_series(1,{BIGROWS}) j")
            kind = BIGROWS
        else:
            sql = f"INSERT INTO t VALUES ({epoch},{w},{i},0,'x')"
            kind = 1
        if execute(c, sql) is None:
            break  # server gone
        if kind is not None:
            acked.append((w, i, kind))
    pq.PQfinish(c)


def main():
    os.makedirs(work, exist_ok=True)
    run("rm", "-rf", pgdata, archive, logfile)
    os.makedirs(archive)
    run(os.path.join(bindir, "initdb"), "-D", pgdata, "--wal-segsize=1",
        "-N", "-A", "trust")
    with open(os.path.join(pgdata, "postgresql.conf"), "a") as f:
        f.write(f"""
port = {port}
unix_socket_directories = '/tmp'
listen_addresses = ''
wal_io_method = aio
io_method = {io_method}
wal_io_max_inflight = 4
wal_buffers = 64kB
max_wal_size = 32MB
min_wal_size = 4MB
checkpoint_timeout = 30s
archive_mode = on
archive_command = 'test ! -f {archive}/%f && cp %p {archive}/%f'
max_connections = 40
log_checkpoints = off
""")
        for kv in extra:
            f.write(kv + "\n")

    p = start_server()
    c = connect()
    execute(c, "CREATE TABLE t (epoch int, w int, i int, j int, pad text, "
               "PRIMARY KEY (epoch, w, i, j))")
    execute(c, "CHECKPOINT")
    pq.PQfinish(c)
    os.sync()   # the setup itself is not under test

    total_acked = 0
    for epoch in range(1, iters + 1):
        stop = threading.Event()
        acked = [[] for _ in range(NWORKERS)]
        threads = [threading.Thread(target=worker, args=(epoch, w, acked[w], stop))
                   for w in range(NWORKERS)]
        for t in threads:
            t.start()
        time.sleep(random.uniform(0.3, 3.0))
        # postmaster children setsid(), so collect them explicitly
        os.kill(p.pid, signal.SIGSTOP)      # no new children from here on
        out = subprocess.run(["pgrep", "-P", str(p.pid)], capture_output=True,
                             text=True).stdout.split()
        children = [int(x) for x in out]
        if POWERCUT:
            # power loss: freeze everything, cut the disk, kill everything;
            # data only in the page cache is lost when the device is restored
            for pid in children:
                os.kill(pid, signal.SIGSTOP)
            devsh("powercut")
            for pid in [p.pid] + children:
                os.kill(pid, signal.SIGKILL)
            mode = "power cut"
        elif epoch % 2 == 1:
            # whole-system crash: freeze everything, then kill everything
            for pid in children:
                os.kill(pid, signal.SIGSTOP)
            for pid in [p.pid] + children:
                os.kill(pid, signal.SIGKILL)
            mode = "all killed"
        else:
            # postmaster dies; children notice and exit by themselves
            os.kill(p.pid, signal.SIGKILL)
            mode = "postmaster killed"
        p.wait()
        stop.set()

        def alive(pid):
            try:
                return open(f"/proc/{pid}/stat").read().split()[2] != "Z"
            except (FileNotFoundError, ProcessLookupError):
                return False
        deadline = time.time() + 30
        while any(alive(pid) for pid in children):
            if time.time() > deadline:
                stuck = [pid for pid in children if alive(pid)]
                print(f"STUCK after postmaster death: {stuck}", flush=True)
                subprocess.run(["ps", "-o", "pid,stat,wchan:30,args", "-p",
                                ",".join(map(str, stuck))])
                for pid in stuck:
                    os.kill(pid, signal.SIGKILL)
                sys.exit(1)
            time.sleep(0.05)
        for t in threads:
            t.join()
        if POWERCUT:
            devsh("restore")

        p = start_server()
        c = connect()
        rows = query_rows(c, f"SELECT w, i, count(*) FROM t WHERE epoch = {epoch} "
                             f"AND pad <> 'async' GROUP BY w, i", 3)
        pq.PQfinish(c)
        present = {(int(w), int(i)): int(n) for w, i, n in rows}

        n = 0
        for w in range(NWORKERS):
            for (ww, i, kind) in acked[w]:
                n += 1
                got = present.get((ww, i))
                if got != kind:
                    sys.exit(f"FAIL epoch {epoch}: acknowledged commit w={ww} i={i} "
                             f"has {got} rows, expected {kind}")
        total_acked += n
        print(f"epoch {epoch} ({mode}): {n} acknowledged commits all present "
              f"({len(present)} committed groups found)", flush=True)

    # clean shutdown, then let the archiver catch up and check its work
    c = connect()
    execute(c, "SELECT pg_switch_wal()")
    execute(c, "CHECKPOINT")
    pq.PQfinish(c)
    for _ in range(200):
        ready = [f for f in os.listdir(os.path.join(pgdata, "pg_wal", "archive_status"))
                 if f.endswith(".ready")]
        if not ready:
            break
        time.sleep(0.1)
    p.send_signal(signal.SIGINT)
    p.wait()
    print(f"OK: {iters} crashes, {total_acked} acknowledged commits verified; "
          f"{len(os.listdir(archive))} segments archived, {len(ready)} still .ready")


main()
