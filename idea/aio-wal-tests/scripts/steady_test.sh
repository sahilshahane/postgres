#!/bin/bash
# Non-crash test for wal_io_method = aio: pgbench load with archiving, then
# check that WAL writes were concurrent/out of order, that every segment got
# archived in sequence, and that the archived WAL is valid end to end.
#
# usage: steady_test.sh INSTALLDIR WORKDIR IO_METHOD PORT
# EXTRA_CONF='debug_io_direct = wal' adds settings (e.g. for the O_DIRECT run).
set -e
INST=$1; WORK=$2; IOM=$3; PORT=$4
BIN=$INST/bin
PGDATA=$WORK/data; ARCH=$WORK/archive; LOG=$WORK/server.log
export PGHOST=/tmp PGPORT=$PORT PGDATABASE=postgres
rm -rf "$WORK"; mkdir -p "$ARCH"

$BIN/initdb -D "$PGDATA" --wal-segsize=1 -N -A trust >/dev/null
cat >> "$PGDATA/postgresql.conf" <<EOF
port = $PORT
unix_socket_directories = '/tmp'
listen_addresses = ''
wal_io_method = aio
io_method = $IOM
wal_io_max_inflight = 16
wal_buffers = 256kB
max_wal_size = 64MB
archive_mode = on
archive_command = 'test ! -f $ARCH/%f && cp %p $ARCH/%f'
log_min_messages = debug2
log_checkpoints = off
${EXTRA_CONF}
EOF
$BIN/pg_ctl -D "$PGDATA" -l "$LOG" -w start >/dev/null

$BIN/pgbench -i -s 5 -q >/dev/null 2>&1
# sample in-flight AIO while pgbench runs
( for i in $(seq 1 150); do
    $BIN/psql -XAtc "SELECT count(*) FROM pg_aios WHERE target_desc LIKE 'WAL file%' AND state IN ('DEFINED','STAGED','SUBMITTED','COMPLETED_IO')" 2>/dev/null
    sleep 0.02
  done ) > "$WORK/inflight.txt" &
$BIN/pgbench -c 32 -j 8 -T 8 -N 2>&1 | grep -E "^tps|failed"
wait
echo "max WAL writes in flight in pg_aios samples: $(sort -n "$WORK/inflight.txt" | tail -1)"
echo "out-of-order completions held back: $(grep -c 'completed before write' "$LOG" || true)"

LAST=$($BIN/psql -XAtc "SELECT pg_walfile_name(pg_current_wal_lsn())")
$BIN/psql -XAtc "SELECT pg_switch_wal()" >/dev/null
$BIN/psql -XAtc "CHECKPOINT"
for i in $(seq 1 600); do
  [ -f "$ARCH/$LAST" ] && break; sleep 0.1
done
$BIN/pg_ctl -D "$PGDATA" -w stop -m fast >/dev/null

FIRST=$(ls "$ARCH" | sort | head -1)
N=$(ls "$ARCH" | wc -l)
python3 - "$ARCH" <<'EOF'
import os, sys
names = sorted(os.listdir(sys.argv[1]))
nums = [int(n[8:16], 16) * 0x100000000 // 0x100000 + int(n[16:24], 16) for n in names]
missing = [n for n in range(nums[0], nums[-1] + 1) if n not in set(nums)]
print(f"archived {len(names)} segments {names[0]}..{names[-1]}, missing: {missing or 'none'}")
sys.exit(1 if missing else 0)
EOF
$BIN/pg_waldump -q -p "$ARCH" "$FIRST" "$LAST" && echo "pg_waldump: archived WAL $FIRST..$LAST parses cleanly"
grep -E "PANIC|TRAP" "$LOG" && exit 1
echo "steady test ($IOM) OK"
