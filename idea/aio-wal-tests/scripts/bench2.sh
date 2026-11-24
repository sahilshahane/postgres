#!/bin/bash
# Interleaved throughput benchmark: stock vs AIO WAL builds/configs.
#
# Unlike bench.sh (all reps of config A, then all of config B), this runs
# rounds: in every round each config gets one run per client count, in a
# rotated order.  Drift over time (SSD garbage collection, other users of the
# machine, thermal) then hits all configs equally, so short runs with several
# rounds give tighter comparisons than long runs back to back.
#
# usage: bench2.sh CONFIGS OUT_RAW.csv
#
# CONFIGS: one config per line, "label|INSTALLDIR|guc = val|guc = val..."
# Environment:
#   GOLDEN    saved data directory (make_golden.sh), copied once per config
#   WORKDIR   where the per-config data directories live (default /mnt/xfs/b2)
#   CLIENTS   client counts (default "1 4 8 16 32 64")
#   SECONDS_  seconds per measured run (default 8)
#   ROUNDS    rounds (default 5)
#   WORKLOAD  pgbench (pgbench -N) | big (big.sql, ~150 kB WAL per commit)
#   PORT      (default 58402)
#   RUN       label stored in the CSV
#   EXTRA_CONF extra postgresql.conf lines for every config (default
#             "full_page_writes = off", see below)
#   COOLDOWN  seconds of idle after each server stop (default 10)
#   CANARY_MAX before each config run, wait (15 s steps, up to 10 min) until
#             the canary is at most this many microseconds (default 700)
#
# The Intel 660p (QLC, ~90% full) in the benchmark machine has a small SLC
# write cache; once sustained writes exhaust it, flush latency rises 20x for
# minutes.  To keep the device in the same state for every run: data
# directories are reflink copies (no data written), full-page writes are off
# by default (the FPI burst after each checkpoint is most of the WAL volume
# and is identical for all configs), the machine idles COOLDOWN seconds after
# each server stop, and every config run starts with a device canary (200
# 8 kB O_DSYNC writes) whose latency is stored with the results, so runs in a
# degraded device state can be spotted.
set -e
CONFIGS=$1; OUT=$2
[ -n "$OUT" ] || { echo "usage: $0 CONFIGS OUT_RAW.csv" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
GOLDEN=${GOLDEN:-/mnt/xfs/golden-s20}   # same fs as WORKDIR: reflink copies, no IO
WORKDIR=${WORKDIR:-/mnt/xfs/b2}
CLIENTS=${CLIENTS:-"1 4 8 16 32 64"}
SECS=${SECONDS_:-8}; ROUNDS=${ROUNDS:-5}; PORT=${PORT:-58402}
WORKLOAD=${WORKLOAD:-pgbench}; RUN=${RUN:-$(date +%Y%m%d-%H%M%S)}
EXTRA_CONF=${EXTRA_CONF-"full_page_writes = off"}; COOLDOWN=${COOLDOWN:-10}
CANARY_MAX=${CANARY_MAX:-700}
export PGHOST=/tmp PGPORT=$PORT PGDATABASE=postgres

mapfile -t CFG < <(grep -v '^\s*\(#\|$\)' "$CONFIGS")
N=${#CFG[@]}

base_conf() {
cat <<EOF
port = $PORT
unix_socket_directories = '/tmp'
listen_addresses = ''
shared_buffers = 1GB
max_wal_size = 8GB
min_wal_size = 2GB
checkpoint_timeout = 30min
max_connections = 200
wal_buffers = 64MB
autovacuum = off
$EXTRA_CONF
EOF
}

# average latency in microseconds of 200 8 kB O_DSYNC writes
canary() {
  local t0 t1
  t0=$(date +%s%N)
  dd if=/dev/zero of="$WORKDIR/canary" bs=8k count=200 oflag=dsync conv=notrunc 2>/dev/null
  t1=$(date +%s%N)
  echo $(( (t1 - t0) / 200000 ))
}

[ -f "$OUT" ] || echo "run,workload,round,config,clients,seconds,tps,latency_avg_ms,canary_us" > "$OUT"

# fresh data directory per config
mkdir -p "$WORKDIR"
for i in $(seq 0 $((N-1))); do
  IFS='|' read -ra p <<< "${CFG[$i]}"
  d=$WORKDIR/d$i
  rm -rf "$d"; cp -a --reflink=auto "$GOLDEN" "$d"
  { base_conf; for kv in "${p[@]:2}"; do echo "$kv"; done; } >> "$d/postgresql.conf"
done

# don't let writeback of the setup overlap the measurements
sync; sleep 3

for r in $(seq 1 "$ROUNDS"); do
  for k in $(seq 0 $((N-1))); do
    i=$(( (k + r) % N ))          # rotate the order every round
    IFS='|' read -ra p <<< "${CFG[$i]}"
    label=${p[0]}; B=${p[1]}/bin; d=$WORKDIR/d$i
    # wait for the device to be in its normal state
    for w in $(seq 1 40); do
      cus=$(canary)
      [ "$cus" -le "$CANARY_MAX" ] && break
      echo "   (device slow: canary $cus us, waiting)"; sleep 15
    done
    $B/pg_ctl -D "$d" -l "$d.log" -w start >/dev/null
    [ "$WORKLOAD" = big ] && $B/psql -XAtqc "TRUNCATE big"
    $B/psql -XAtqc CHECKPOINT
    # short warm-up, not recorded
    if [ "$WORKLOAD" = big ]; then
      $B/pgbench -n -f "$HERE/big.sql" -c 8 -j 8 -T 2 >/dev/null 2>&1
    else
      $B/pgbench -N -c 8 -j 8 -T 2 >/dev/null 2>&1
    fi
    for c in $CLIENTS; do
      j=$(( c < 16 ? c : 16 ))
      if [ "$WORKLOAD" = big ]; then
        $B/psql -XAtqc "TRUNCATE big; CHECKPOINT"
        res=$($B/pgbench -n -f "$HERE/big.sql" -c $c -j $j -T "$SECS" 2>&1)
      else
        res=$($B/pgbench -N -c $c -j $j -T "$SECS" 2>&1)
      fi
      read -r tps lat < <(echo "$res" | awk '/^tps/ {tps=$3} /^latency average/ {lat=$4} END {print tps, lat}')
      echo "$RUN,$WORKLOAD,$r,\"$label\",$c,$SECS,$tps,$lat,$cus" >> "$OUT"
      printf "r%-2s %-40s c=%-4s %9.0f tps  (canary %s us)\n" "$r" "$label" "$c" "$tps" "$cus"
    done
    $B/pg_ctl -D "$d" -w stop -m fast >/dev/null
    sync; sleep "$COOLDOWN"
  done
done
echo DONE
