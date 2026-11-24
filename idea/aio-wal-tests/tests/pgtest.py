"""Shared helpers for the AIO WAL correctness tests: a minimal libpq binding
(ctypes, no extra Python packages), a server wrapper that can be crashed in
the ways the tests need, the workload that records acknowledged commits, and
the "chaos" thread that reloads the AIO GUCs under load.
"""
import ctypes, glob, os, random, signal, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))


def read_modes(path=os.path.join(HERE, "modes.txt")):
    """modes.txt: 'name|guc = val|guc = val...'; returns {name: [lines]}."""
    modes = {}
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#"):
            name, *gucs = [x.strip() for x in line.split("|")]
            modes[name] = gucs
    return modes


class Libpq:
    def __init__(self, inst):
        libs = sorted(glob.glob(os.path.join(inst, "lib*", "**", "libpq.so*"),
                                recursive=True))
        if not libs:
            sys.exit(f"libpq not found under {inst}")
        pq = ctypes.CDLL(libs[0])
        pq.PQconnectdb.restype = ctypes.c_void_p
        pq.PQconnectdb.argtypes = [ctypes.c_char_p]
        pq.PQstatus.argtypes = [ctypes.c_void_p]
        pq.PQexec.restype = ctypes.c_void_p
        pq.PQexec.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        pq.PQresultStatus.argtypes = [ctypes.c_void_p]
        pq.PQclear.argtypes = [ctypes.c_void_p]
        pq.PQfinish.argtypes = [ctypes.c_void_p]
        pq.PQntuples.argtypes = [ctypes.c_void_p]
        pq.PQnfields.argtypes = [ctypes.c_void_p]
        pq.PQgetvalue.restype = ctypes.c_char_p
        pq.PQgetvalue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        pq.PQerrorMessage.restype = ctypes.c_char_p
        pq.PQerrorMessage.argtypes = [ctypes.c_void_p]
        self.pq = pq

    def connect(self, port):
        c = self.pq.PQconnectdb(f"host=/tmp port={port} dbname=postgres".encode())
        if self.pq.PQstatus(c) != 0:
            self.pq.PQfinish(c)
            return None
        return c

    def execute(self, c, sql):
        """Rows as lists of str, or None if the statement failed."""
        r = self.pq.PQexec(c, sql.encode())
        st = self.pq.PQresultStatus(r) if r else -1
        if st not in (1, 2):            # PGRES_COMMAND_OK, PGRES_TUPLES_OK
            if r:
                self.pq.PQclear(r)
            return None
        rows = [[(self.pq.PQgetvalue(r, i, j) or b"").decode()
                 for j in range(self.pq.PQnfields(r))]
                for i in range(self.pq.PQntuples(r))]
        self.pq.PQclear(r)
        return rows

    def finish(self, c):
        self.pq.PQfinish(c)


class Server:
    """One PostgreSQL instance.  Started directly (not via pg_ctl) so that the
    tests know the postmaster's pid and can kill it at any moment."""

    def __init__(self, inst, datadir, port, pq):
        self.inst, self.datadir, self.port, self.pq = inst, datadir, port, pq
        self.bin = os.path.join(inst, "bin")
        self.log = datadir + ".log"
        self.proc = None

    def initdb(self, conf_lines):
        subprocess.run(["rm", "-rf", self.datadir, self.log], check=True)
        run(os.path.join(self.bin, "initdb"), "-D", self.datadir,
            "--wal-segsize=1", "-N", "-A", "trust")
        self.append_conf(conf_lines)

    def append_conf(self, conf_lines):
        with open(os.path.join(self.datadir, "postgresql.conf"), "a") as f:
            f.write(f"\nport = {self.port}\nunix_socket_directories = '/tmp'\n"
                    "listen_addresses = ''\nlog_checkpoints = off\n")
            for kv in conf_lines:
                f.write(kv + "\n")

    def start(self, timeout=120):
        log = open(self.log, "a")
        self.proc = subprocess.Popen([os.path.join(self.bin, "postgres"), "-D",
                                      self.datadir], stdout=log, stderr=log,
                                     start_new_session=True)
        deadline = time.time() + timeout
        while time.time() < deadline:
            c = self.pq.connect(self.port)
            if c:
                # a standby accepts connections before it streams; that's fine
                self.pq.finish(c)
                return
            if self.proc.poll() is not None:
                fail(f"server exited during startup, see {self.log}")
            time.sleep(0.05)
        fail(f"server did not start, see {self.log}")

    def children(self):
        out = subprocess.run(["pgrep", "-P", str(self.proc.pid)],
                             capture_output=True, text=True).stdout.split()
        return [int(x) for x in out]

    def crash(self, mode):
        """'all': freeze and SIGKILL every process (OS crash); 'postmaster':
        SIGKILL only the postmaster, the children must exit by themselves
        (they may still be finishing IO).  Returns when all are gone."""
        os.kill(self.proc.pid, signal.SIGSTOP)      # no new children
        kids = self.children()
        if mode == "all":
            for pid in kids:
                os.kill(pid, signal.SIGSTOP)
            for pid in [self.proc.pid] + kids:
                os.kill(pid, signal.SIGKILL)
        else:
            os.kill(self.proc.pid, signal.SIGKILL)
        self.proc.wait()
        deadline = time.time() + 30
        while any(alive(p) for p in kids):
            if time.time() > deadline:
                stuck = [p for p in kids if alive(p)]
                subprocess.run(["ps", "-o", "pid,stat,wchan:30,args", "-p",
                                ",".join(map(str, stuck))])
                for p in stuck:
                    os.kill(p, signal.SIGKILL)
                fail(f"backends stuck after postmaster death: {stuck}")
            time.sleep(0.05)
        self.proc = None

    def stop(self):
        if self.proc:
            self.proc.send_signal(signal.SIGINT)     # fast shutdown
            self.proc.wait()
            self.proc = None

    def sql(self, q, check=True):
        """Run q with psql, return stdout stripped."""
        r = subprocess.run([os.path.join(self.bin, "psql"), "-XAtq", "-h", "/tmp",
                            "-p", str(self.port), "-d", "postgres",
                            "-v", "ON_ERROR_STOP=1", "-c", q],
                           capture_output=True, text=True)
        if check and r.returncode != 0:
            fail(f"psql on port {self.port} failed: {q}\n{r.stderr}")
        return r.stdout.strip()

    def log_problems(self):
        """PANIC / assertion failures / unexpected FATALs in the server log."""
        bad = []
        for line in open(self.log, errors="replace"):
            if ("PANIC" in line or "TRAP:" in line or "was terminated by signal 6" in line
                    or "ahead of the WAL flush position" in line):
                bad.append(line.rstrip())
        return bad


def alive(pid):
    try:
        return open(f"/proc/{pid}/stat").read().split()[2] != "Z"
    except (FileNotFoundError, ProcessLookupError):
        return False


def run(*args, **kw):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, **kw)


def fail(msg):
    print(f"FAIL: {msg}", flush=True)
    sys.exit(1)


# ---------------------------------------------------------------- workload

TABLE_DDL = ("CREATE TABLE t (epoch int, w int, i int, j int, pad text, "
             "PRIMARY KEY (epoch, w, i, j))")
BIGROWS = 40


def worker(pq, port, epoch, w, acked, stop):
    """Commit transactions until the server goes away or stop is set.  Every
    commit the server acknowledged as durable is appended to 'acked' as
    (w, i, rows).  Mix: small commits (group commit), large ones (many WAL
    pages, pipelining), async commits (WAL writer path, not recorded), and
    two-phase commits (recorded after COMMIT PREPARED)."""
    c = pq.connect(port)
    if not c:
        return
    i = 0
    while not stop.is_set():
        i += 1
        r = random.random()
        if r < 0.05:
            sql = (f"SET synchronous_commit = off; INSERT INTO t VALUES "
                   f"({epoch},{w},{i},0,'async'); RESET synchronous_commit")
            kind = None
        elif r < 0.20:
            sql = (f"INSERT INTO t SELECT {epoch},{w},{i},j,repeat(md5(j::text), 60) "
                   f"FROM generate_series(1,{BIGROWS}) j")
            kind = BIGROWS
        elif r < 0.23:
            g = f"g_{epoch}_{w}_{i}"
            sql = (f"BEGIN; INSERT INTO t VALUES ({epoch},{w},{i},0,'2pc'); "
                   f"PREPARE TRANSACTION '{g}'; COMMIT PREPARED '{g}'")
            kind = 1
        else:
            sql = f"INSERT INTO t VALUES ({epoch},{w},{i},0,'x')"
            kind = 1
        if pq.execute(c, sql) is None:
            break                       # server gone
        if kind is not None:
            acked.append((w, i, kind))
    pq.finish(c)


class Load:
    """NWORKERS workers committing into t for one epoch."""

    def __init__(self, pq, port, epoch, nworkers=16):
        self.stop = threading.Event()
        self.acked = [[] for _ in range(nworkers)]
        self.threads = [threading.Thread(target=worker, daemon=True,
                                         args=(pq, port, epoch, w, self.acked[w], self.stop))
                        for w in range(nworkers)]
        self.epoch = epoch
        for t in self.threads:
            t.start()

    def finish(self):
        self.stop.set()
        for t in self.threads:
            t.join()

    def verify(self, srv):
        """Every acknowledged commit of this epoch must be present in full."""
        rows = srv.sql(f"SELECT w, i, count(*) FROM t WHERE epoch = {self.epoch} "
                       f"AND pad <> 'async' GROUP BY w, i")
        present = {}
        for line in rows.splitlines():
            w, i, n = line.split("|")
            present[(int(w), int(i))] = int(n)
        n = 0
        for lst in self.acked:
            for (w, i, kind) in lst:
                n += 1
                if present.get((w, i)) != kind:
                    fail(f"epoch {self.epoch}: acknowledged commit w={w} i={i} has "
                         f"{present.get((w, i))} rows after recovery, expected {kind}")
        return n


def amcheck(srv):
    """Heap and index of t must be consistent (catches torn / reordered WAL
    that recovery replayed without noticing)."""
    srv.sql("CREATE EXTENSION IF NOT EXISTS amcheck")
    srv.sql("SELECT bt_index_check('t_pkey', true)")
    bad =srv.sql("SELECT count(*) FROM verify_heapam('t')")
    if bad != "0":
        fail(f"verify_heapam found {bad} corrupt tuples")


# ------------------------------------------------------------------- chaos

CHAOS_CHOICES = {
    "wal_io_max_inflight": ["1", "2", "4", "16", "64"],
    "wal_io_pipeline_threshold": ["0", "'8kB'", "'256kB'", "'4MB'"],
    "wal_io_eager_issue": ["on", "off"],
    "wal_io_inline_fsync": ["on", "off"],
    # changing it closes and reopens the WAL segment; every method is durable
    "wal_sync_method": ["fdatasync", "fsync", "open_datasync", "open_sync"],
}


class Chaos:
    """Reload random values of the SIGHUP AIO GUCs every 50-300 ms while the
    load runs.  Changes go to postgresql.auto.conf; reset() removes them."""

    def __init__(self, pq, port, enabled=True):
        self.pq, self.port = pq, port
        self.stop = threading.Event()
        self.reloads = 0
        self.thread = threading.Thread(target=self._run, daemon=True)
        if enabled:
            self.thread.start()

    def _run(self):
        c = self.pq.connect(self.port)
        if not c:
            return
        while not self.stop.is_set():
            g = random.choice(list(CHAOS_CHOICES))
            v = random.choice(CHAOS_CHOICES[g])
            if (self.pq.execute(c, f"ALTER SYSTEM SET {g} = {v}") is None or
                    self.pq.execute(c, "SELECT pg_reload_conf()") is None):
                break
            self.reloads += 1
            time.sleep(random.uniform(0.05, 0.3))
        self.pq.finish(c)

    def finish(self):
        self.stop.set()
        if self.thread.is_alive():
            self.thread.join()


def reset_chaos(srv):
    srv.sql("ALTER SYSTEM RESET ALL")
    srv.sql("SELECT pg_reload_conf()")


def result(**kw):
    """Last line of every test: machine readable for run_all.py."""
    print("RESULT " + " ".join(f"{k}={v}" for k, v in kw.items()), flush=True)
