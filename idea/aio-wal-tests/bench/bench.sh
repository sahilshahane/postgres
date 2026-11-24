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
#   CLIENTS ("16 32 64"), SECONDS_ per run (5), ROUNDS (8), BASEPORT (58500)
#   CANARY_MAX  before each block, wait until 200 x 8 kB O_DSYNC writes average
#               at most this many us (700; set ~3x the device's normal value)
#   QUIESCE     1: after each run, CHECKPOINT that server and sync, so the next
#               run doesn't share the device with this run's leftover data
#               writes (dirty shared buffers and page cache); default 0
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
  *) echo "WORKLOAD must be pgbench, big or bigpc" >&2; exit 1 ;;
esac
EXTRA_CONF=${EXTRA_CONF-"full_page_writes = off"}; RUN=${RUN:-paired}; QUIESCE=${QUIESCE:-0}
export PGHOST=/tmp PGDATABASE=postgres

mapfile -t CFG < <(grep -v '^\s*\(#\|$\)' "$CONFIGS")
N=${#CFG[@]}

canary() {
  local t0 t1; t0=$(date +%s%N)
  dd if=/dev/zero of="$WORKDIR/canary" bs=8k count=200 oflag=dsync conv=notrunc 2>/dev/null
  t1=$(date +%s%N); echo $(( (t1 - t0) / 200000 ))
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
trap stop_all EXIT

mkdir -p "$WORKDIR"
for i in $(seq 0 $((N-1))); do
  IFS='|' read -ra p <<< "${CFG[$i]}"
  d=$WORKDIR/d$i
  rm -rf "$d"; cp -a --reflink=auto "$GOLDEN" "$d"
  cat >> "$d/postgresql.conf" <<EOF
port = $((BASEPORT + i))
unix_socket_directories = '/tmp'
listen_addresses = ''
shared_buffers = 512MB
max_wal_size = 8GB
min_wal_size = 2GB
checkpoint_timeout = 60min
max_connections = 200
wal_buffers = 64MB
autovacuum = off
$EXTRA_CONF
EOF
  for kv in "${p[@]:2}"; do echo "$kv" >> "$d/postgresql.conf"; done
done
sync; sleep 3
for i in $(seq 0 $((N-1))); do
  IFS='|' read -ra p <<< "${CFG[$i]}"
  "${p[1]}/bin/pg_ctl" -D "$WORKDIR/d$i" -l "$WORKDIR/d$i.log" -w start >/dev/null
  PGPORT=$((BASEPORT + i)) "${p[1]}/bin/psql" -XAtqc CHECKPOINT
  PGPORT=$((BASEPORT + i)) "${p[1]}/bin/pgbench" $PGB_ARGS -c 8 -j 8 -T 3 >/dev/null 2>&1
done

[ -f "$OUT" ] || echo "run,workload,round,config,clients,seconds,tps,latency_avg_ms,canary_us" > "$OUT"
for r in $(seq 1 "$ROUNDS"); do
  for c in $CLIENTS; do
    for w in $(seq 1 40); do
      cus=$(canary); [ "$cus" -le "$CANARY_MAX" ] && break
      echo "   (device slow: canary $cus us, waiting)"; sleep 15
    done
    j=$(( c < 16 ? c : 16 ))
    for k in $(seq 0 $((N-1))); do
      i=$(( (k + r) % N ))
      IFS='|' read -ra p <<< "${CFG[$i]}"
      [ "$WORKLOAD" = big ] && PGPORT=$((BASEPORT + i)) "${p[1]}/bin/psql" -XAtqc "TRUNCATE big"
      [ "$WORKLOAD" = bigpc ] && PGPORT=$((BASEPORT + i)) "${p[1]}/bin/psql" -XAtqc "TRUNCATE bigc"
      res=$(PGPORT=$((BASEPORT + i)) "${p[1]}/bin/pgbench" $PGB_ARGS -c $c -j $j -T "$SECS" 2>&1)
      if [ "$QUIESCE" = 1 ]; then
        PGPORT=$((BASEPORT + i)) "${p[1]}/bin/psql" -XAtqc "CHECKPOINT" >/dev/null 2>&1; sync
      fi
      read -r tps lat < <(echo "$res" | awk '/^tps/ {tps=$3} /^latency average/ {lat=$4} END {print tps, lat}')
      echo "$RUN,$WORKLOAD,$r,\"${p[0]}\",$c,$SECS,$tps,$lat,$cus" >> "$OUT"
      printf "r%-2s %-40s c=%-4s %9.0f tps  (canary %s us)\n" "$r" "${p[0]}" "$c" "$tps" "$cus"
    done
  done
done
echo DONE
