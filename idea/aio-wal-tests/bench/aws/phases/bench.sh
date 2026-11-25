#!/bin/bash
# Tightly paired throughput benchmark.  All configs' servers run at the same
# time (on their own ports and data directories), and pgbench alternates
# between them: for every repetition and client count, each config gets one
# short run, in an order rotated every repetition.  Runs of different configs
# are seconds apart, so changes in the SSD's speed (see bench2.sh) hit them
# alike.  Output has the same columns as bench2.sh (round = repetition), so
# summarize2.py and paired2.py read it.
#
# Summarize/compare with analyze.py.
#
# usage: bench.sh CONFIGS OUT_RAW.csv
# CONFIGS: one config per line, "label|INSTALLDIR|guc = val|..." (see cfg_*.txt)
# Environment:
#   GOLDEN      data directory from make_golden.sh, reflink-copied per config
#   WORKDIR     per-config data directories, same filesystem as GOLDEN (/mnt/xfs/b3)
#   WORKLOAD    pgbench (pgbench -N, ~0.5 kB WAL per commit) |
#               big (big.sql, 500-row insert, ~150 kB WAL per commit)
#               bigpc (bigpc.sql: the same, into one table per client)
#               Standard benchmarks (golden from make_golden_std.sh):
#               tpcc (BenchBase TPC-C, BB_SCALE warehouses, default 16) |
#               ycsb (BenchBase YCSB workload A: 50% read, 50% update) |
#               sysbench-wo (sysbench oltp_write_only) |
#               sysbench-ins (sysbench oltp_insert) |
#               copy (copy.sql: COPY of 50,000 rows, ~13 MB, into one table)
#   Standard workloads read their tables: before measuring, the page cache is
#   dropped and each config's copy of the workload's tables and indexes is read
#   into it (cat of the relation files), so no run reads from the device (cold
#   copies made TPC-C runs bimodal: reads compete with WAL writes for IOPS).
#   BB_HOME     unpacked BenchBase (postgres profile), default ~/benchbase
#   CLIENTS ("16 32 64"), SECONDS_ per run (5), ROUNDS (8), BASEPORT (58500)
#   CANARY_MAX  before each block, wait until 200 x 8 kB O_DSYNC writes average
#               at most this many us (700; set ~3x the device's normal value)
#   QUIESCE     1: after each run, CHECKPOINT that server and sync, so the next
#               run doesn't share the device with this run's leftover data
#               writes (dirty shared buffers and page cache); default 0
#   Config items "sys.max_sectors_kb = N" are not written to postgresql.conf:
#   before each run of that config, the WORKDIR device's max_sectors_kb (the
#   largest request the kernel sends it; larger IOs are split) is set to N;
#   configs without it get the device's value at start.  Needs sudo.
#   EXTRA_CONF  extra postgresql.conf lines (default full_page_writes = off:
#               the post-checkpoint FPI burst is identical for all configs)
#   KEEP=1      keep the data directories afterwards
set -e
CONFIGS=$1; OUT=$2
[ -n "$OUT" ] || { echo "usage: $0 CONFIGS OUT_RAW.csv" >&2; exit 1; }
GOLDEN=${GOLDEN:-/mnt/xfs/golden-s20}; WORKDIR=${WORKDIR:-/mnt/xfs/b3}
CLIENTS=${CLIENTS:-"16 32 64"}; SECS=${SECONDS_:-5}; ROUNDS=${ROUNDS:-8}
CANARY_MAX=${CANARY_MAX:-700}; BASEPORT=${BASEPORT:-58500}
WORKLOAD=${WORKLOAD:-pgbench}; HERE=$(cd "$(dirname "$0")" && pwd)
case $WORKLOAD in
  pgbench) PGB_ARGS="-N" ;;
  big)     PGB_ARGS="-n -f $HERE/big.sql" ;;
  bigpc)   PGB_ARGS="-n -f $HERE/bigpc.sql" ;;
  copy)    PGB_ARGS="-n -f $HERE/copy.sql" ;;
  tpcc|ycsb) KIND=benchbase; BB_BENCH=$WORKLOAD ;;
  sysbench-wo)  KIND=sysbench; SB_TEST=oltp_write_only ;;
  sysbench-ins) KIND=sysbench; SB_TEST=oltp_insert ;;
  *) echo "WORKLOAD must be pgbench, big, bigpc, copy, tpcc, ycsb, sysbench-wo or sysbench-ins" >&2; exit 1 ;;
esac
case $WORKLOAD in
  tpcc) PREWARM='^(warehouse|district|customer|history|oorder|new_order|order_line|stock|item)$' ;;
  ycsb) PREWARM='^usertable$' ;;
  sysbench-*) PREWARM='^sbtest[0-9]+$' ;;
esac
KIND=${KIND:-pgbench}; BB_HOME=${BB_HOME:-$HOME/benchbase}
BB_SCALE=${BB_SCALE:-$([ "$WORKLOAD" = ycsb ] && echo 1000 || echo 16)}
SB_TABLES=${SB_TABLES:-8}; SB_SIZE=${SB_SIZE:-100000}
LISTEN=$([ "$KIND" = benchbase ] && echo localhost)   # JDBC needs TCP
EXTRA_CONF=${EXTRA_CONF-"full_page_writes = off"}; RUN=${RUN:-paired}; QUIESCE=${QUIESCE:-0}
export PGHOST=/tmp PGDATABASE=postgres

mapfile -t CFG < <(grep -v '^\s*\(#\|$\)' "$CONFIGS")
N=${#CFG[@]}

# device of WORKDIR, for sys.max_sectors_kb
mkdir -p "$WORKDIR"
SYSDEV=$(lsblk -no PKNAME "$(findmnt -no SOURCE --target "$WORKDIR")" 2>/dev/null)
[ -n "$SYSDEV" ] || SYSDEV=$(basename "$(findmnt -no SOURCE --target "$WORKDIR")")
MSK_FILE=/sys/block/$SYSDEV/queue/max_sectors_kb
MSK_DEFAULT=$(cat "$MSK_FILE" 2>/dev/null)
set_msk() {   # config index
  local v=$MSK_DEFAULT kv
  IFS='|' read -ra q <<< "${CFG[$1]}"
  for kv in "${q[@]:2}"; do
    case $kv in sys.max_sectors_kb*) v=$(echo "${kv#*=}" | tr -d ' ') ;; esac
  done
  [ "$(cat "$MSK_FILE")" = "$v" ] || echo "$v" | sudo tee "$MSK_FILE" >/dev/null
}

canary() {
  local t0 t1; t0=$(date +%s%N)
  dd if=/dev/zero of="$WORKDIR/canary" bs=8k count=200 oflag=dsync conv=notrunc 2>/dev/null
  t1=$(date +%s%N); echo $(( (t1 - t0) / 200000 ))
}

# One measured run: run_one CFG_INDEX CLIENTS SECONDS prints "tps latency_ms"
# (BenchBase: requests/s, sysbench: transactions/s, pgbench: tps).
run_one() {
  local i=$1 c=$2 s=$3 port=$((BASEPORT + $1)) j res
  j=$(( c < 16 ? c : 16 ))
  IFS='|' read -ra p <<< "${CFG[$i]}"
  case $KIND in
    pgbench)
      res=$(PGPORT=$port "${p[1]}/bin/pgbench" $PGB_ARGS -c $c -j $j -T "$s" 2>&1)
      echo "$res" | awk '/^tps/ {tps=$3} /^latency average/ {lat=$4} END {print tps, lat}' ;;
    sysbench)
      res=$(sysbench $SB_TEST --db-driver=pgsql --pgsql-host=/tmp --pgsql-port=$port \
              --pgsql-user="$USER" --pgsql-db=postgres --tables=$SB_TABLES \
              --table-size=$SB_SIZE --threads=$c --time=$s --report-interval=0 run 2>&1)
      echo "$res" | awk '/^ *transactions:/ {gsub(/\(/, "", $3); tps=$3} /^ *avg:/ {lat=$2} END {print tps, lat}' ;;
    benchbase)
      local od=$WORKDIR/bbout$i
      python3 "$HERE/bbconf.py" "$BB_HOME" "$BB_BENCH" "$WORKDIR/bb$i.xml" $port $c $s "$BB_SCALE"
      rm -rf "$od"
      (cd "$BB_HOME" && java -jar benchbase.jar -b $BB_BENCH -c "$WORKDIR/bb$i.xml" \
         --execute=true -d "$od" > "$od.log" 2>&1) || true
      python3 "$HERE/bbconf.py" --parse "$od" ;;
  esac
}

# Stop the servers and, unless KEEP=1, remove their data directories: each
# grows by gigabytes of WAL, and leftovers of several runs fill the partition.
stop_all() {
  for i in $(seq 0 $((N-1))); do
    IFS='|' read -ra p <<< "${CFG[$i]}"
    "${p[1]}/bin/pg_ctl" -D "$WORKDIR/d$i" -w stop -m fast >/dev/null 2>&1 || true
    [ "${KEEP:-0}" = 1 ] || rm -rf "$WORKDIR/d$i"
  done
}
trap 'stop_all; [ -n "$MSK_DEFAULT" ] && echo "$MSK_DEFAULT" | sudo tee "$MSK_FILE" >/dev/null' EXIT

mkdir -p "$WORKDIR"
for i in $(seq 0 $((N-1))); do
  IFS='|' read -ra p <<< "${CFG[$i]}"
  d=$WORKDIR/d$i
  rm -rf "$d"; cp -a --reflink=auto "$GOLDEN" "$d"
  cat >> "$d/postgresql.conf" <<EOF
port = $((BASEPORT + i))
unix_socket_directories = '/tmp'
listen_addresses = '$LISTEN'
shared_buffers = 512MB
max_wal_size = 8GB
min_wal_size = 2GB
checkpoint_timeout = 60min
max_connections = 200
wal_buffers = 64MB
autovacuum = off
$EXTRA_CONF
EOF
  for kv in "${p[@]:2}"; do case $kv in sys.*) ;; *) echo "$kv" >> "$d/postgresql.conf" ;; esac; done
done
sync; sleep 3
for i in $(seq 0 $((N-1))); do
  IFS='|' read -ra p <<< "${CFG[$i]}"
  "${p[1]}/bin/pg_ctl" -D "$WORKDIR/d$i" -l "$WORKDIR/d$i.log" -w start >/dev/null
  PGPORT=$((BASEPORT + i)) "${p[1]}/bin/psql" -XAtqc CHECKPOINT
  [ "$WORKLOAD" = copy ] && PGPORT=$((BASEPORT + i)) "${p[1]}/bin/psql" -XAtqc \
    "COPY (SELECT g, repeat(md5(g::text), 8) FROM generate_series(1, 50000) g) TO '/dev/shm/bulk.csv'"
  run_one $i 8 3 >/dev/null 2>&1
  [ "$WORKLOAD" = copy ] && PGPORT=$((BASEPORT + i)) "${p[1]}/bin/psql" -XAtqc "TRUNCATE bulk"
done

if [ -n "$PREWARM" ]; then
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  for i in $(seq 0 $((N-1))); do
    IFS='|' read -ra p <<< "${CFG[$i]}"
    PGPORT=$((BASEPORT + i)) "${p[1]}/bin/psql" -XAtc "
      SELECT pg_relation_filepath(c.oid) FROM pg_class c
      WHERE c.relkind IN ('r', 'i', 't') AND (c.relname ~ '$PREWARM'
        OR c.oid IN (SELECT indexrelid FROM pg_index x JOIN pg_class t ON t.oid = x.indrelid WHERE t.relname ~ '$PREWARM')
        OR c.oid IN (SELECT reltoastrelid FROM pg_class WHERE relname ~ '$PREWARM'))" |
    while read -r f; do cat "$WORKDIR/d$i/$f" "$WORKDIR/d$i/$f".[0-9]* 2>/dev/null || true; done | wc -c |
      awk -v i=$i '{printf "prewarmed d%d: %.0f MB\n", i, $1 / 1048576}'
  done
  free -m | awk '/^Mem/ {print "page cache after prewarm: " $6 " MB, available " $7 " MB"}'
fi

[ -f "$OUT" ] || echo "run,workload,round,config,clients,seconds,tps,latency_avg_ms,canary_us" > "$OUT"
for r in $(seq 1 "$ROUNDS"); do
  for c in $CLIENTS; do
    for w in $(seq 1 40); do
      cus=$(canary); [ "$cus" -le "$CANARY_MAX" ] && break
      echo "   (device slow: canary $cus us, waiting)"; sleep 15
    done
    for k in $(seq 0 $((N-1))); do
      i=$(( (k + r) % N ))
      IFS='|' read -ra p <<< "${CFG[$i]}"
      [ "$WORKLOAD" = big ] && PGPORT=$((BASEPORT + i)) "${p[1]}/bin/psql" -XAtqc "TRUNCATE big"
      [ "$WORKLOAD" = bigpc ] && PGPORT=$((BASEPORT + i)) "${p[1]}/bin/psql" -XAtqc "TRUNCATE bigc"
      [ "$WORKLOAD" = copy ] && PGPORT=$((BASEPORT + i)) "${p[1]}/bin/psql" -XAtqc "TRUNCATE bulk"
      set_msk $i
      read -r tps lat < <(run_one $i $c "$SECS")
      if [ "$QUIESCE" = 1 ]; then
        PGPORT=$((BASEPORT + i)) "${p[1]}/bin/psql" -XAtqc "CHECKPOINT" >/dev/null 2>&1; sync
      fi
      echo "$RUN,$WORKLOAD,$r,\"${p[0]}\",$c,$SECS,$tps,$lat,$cus" >> "$OUT"
      printf "r%-2s %-40s c=%-4s %9.0f tps  (canary %s us)\n" "$r" "${p[0]}" "$c" "$tps" "$cus"
    done
  done
done
echo DONE
