#!/bin/bash
# Throughput benchmark of WAL write paths.  Appends one row per
# (config, clients) to a CSV with the same columns as results/throughput.csv,
# so new runs can be plotted together with the recorded ones.
#
# usage: bench.sh INSTALLDIR DATADIR OUT.csv
#
# Environment (all optional):
#   WORKLOAD   pgbench (default; pgbench -N, scale 20) | big (scripts/big.sql)
#   CLIENTS    client counts            (default "1 8 32 128")
#   SECONDS_   seconds per run          (default 10)
#   REPS       runs per point; median is recorded (default 3)
#   CONFIGS    file with one config per line: "label|guc = val|guc = val..."
#              (default: the configs used in the recorded results, below)
#   RUN, CODE_VERSION, STORAGE, LATENCY_MS, WRITE_CACHE   labels for the CSV
#   PORT       (default 58302)
set -e
INST=$1; PGD=$2; OUT=$3
[ -n "$OUT" ] || { echo "usage: $0 INSTALLDIR DATADIR OUT.csv" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
B=$INST/bin
WORKLOAD=${WORKLOAD:-pgbench}; CLIENTS=${CLIENTS:-"1 8 32 128"}
SECS=${SECONDS_:-10}; REPS=${REPS:-3}; PORT=${PORT:-58302}
RUN=${RUN:-$(date +%Y%m%d-%H%M%S)}; CODE_VERSION=${CODE_VERSION:-v4}
STORAGE=${STORAGE:-unknown}; LATENCY_MS=${LATENCY_MS:-}; WRITE_CACHE=${WRITE_CACHE:-}
export PGHOST=/tmp PGPORT=$PORT PGDATABASE=postgres

default_configs() {
cat <<'EOF'
stock fdatasync|wal_io_method = sync|wal_sync_method = fdatasync
stock open_datasync|wal_io_method = sync|wal_sync_method = open_datasync
aio uring inflight=1|wal_io_method = aio|io_method = io_uring|wal_io_max_inflight = 1
aio uring inflight=4|wal_io_method = aio|io_method = io_uring|wal_io_max_inflight = 4
aio uring inflight=16|wal_io_method = aio|io_method = io_uring|wal_io_max_inflight = 16
aio worker inflight=16|wal_io_method = aio|io_method = worker|wal_io_max_inflight = 16
aio uring inflight=16+DIO|wal_io_method = aio|io_method = io_uring|wal_io_max_inflight = 16|debug_io_direct = wal
EOF
}

base_conf() {
cat <<EOF
port = $PORT
unix_socket_directories = '/tmp'
listen_addresses = ''
shared_buffers = 1GB
max_wal_size = 8GB
checkpoint_timeout = 30min
max_connections = 200
wal_buffers = 64MB
EOF
}

[ -f "$OUT" ] || echo "run,code_version,storage,latency_ms,write_cache,workload,stat,config,wal_io_method,io_method,wal_io_max_inflight,direct_io,wal_sync_method,clients,tps,latency_avg_ms" > "$OUT"

if [ "$WORKLOAD" = big ]; then wl="large txn (big.sql)"; else wl="pgbench -N scale 20"; fi
stat="median of $REPS x ${SECS}s"; [ "$REPS" = 1 ] && stat="single ${SECS}s"

while IFS= read -r cfg; do
  [ -z "$cfg" ] && continue
  IFS='|' read -ra parts <<< "$cfg"
  label=${parts[0]}
  # fresh cluster per config (large transactions fill the disk otherwise)
  rm -rf "$PGD"; $B/initdb -D "$PGD" -A trust >/dev/null
  { base_conf; for kv in "${parts[@]:1}"; do echo "$kv"; done; } >> "$PGD/postgresql.conf"
  $B/pg_ctl -D "$PGD" -l "$PGD.log" -w start >/dev/null
  if [ "$WORKLOAD" = big ]; then
    $B/psql -XAtqc "CREATE TABLE big(id int, pad text)"
  else
    $B/pgbench -i -s 20 -q >/dev/null 2>&1
  fi
  $B/psql -XAtqc CHECKPOINT
  # settings columns
  walio=sync; iom=""; infl=""; dio=no; wsm=""
  for kv in "${parts[@]:1}"; do
    k=$(echo "${kv%%=*}" | xargs); v=$(echo "${kv#*=}" | xargs)
    case $k in
      wal_io_method) walio=$v;; io_method) iom=$v;; wal_io_max_inflight) infl=$v;;
      debug_io_direct) dio=yes;; wal_sync_method) wsm=$v;;
    esac
  done
  [ "$walio" = sync ] && iom=""
  [ "$walio" = sync ] && [ -z "$wsm" ] && wsm=fdatasync
  [ "$walio" = aio ] && [ -z "$iom" ] && iom=worker
  [ "$walio" = aio ] && [ -z "$infl" ] && infl=1
  line=""
  for c in $CLIENTS; do
    j=$(( c < 8 ? c : 8 ))
    res=$(for r in $(seq 1 "$REPS"); do
      [ "$WORKLOAD" = big ] && $B/psql -XAtqc "TRUNCATE big; CHECKPOINT"
      if [ "$WORKLOAD" = big ]; then
        $B/pgbench -n -f "$HERE/big.sql" -c $c -j $j -T "$SECS" 2>&1
      else
        $B/pgbench -N -c $c -j $j -T "$SECS" 2>&1
      fi | awk '/^tps/ {tps=$3} /^latency average/ {lat=$4} END {print tps, lat}'
    done | sort -n | sed -n "$(( (REPS + 1) / 2 ))p")
    tps=${res% *}; lat=${res#* }
    printf '%s,%s,"%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%.0f,%s\n' \
      "$RUN" "$CODE_VERSION" "$STORAGE" "$LATENCY_MS" "$WRITE_CACHE" "$wl" "$stat" \
      "$label" "$walio" "$iom" "$infl" "$dio" "$wsm" "$c" "$tps" "$lat" >> "$OUT"
    line="$line $(printf '%8.0f' "$tps")"
  done
  printf "%-28s %s\n" "$label" "$line"
  $B/pg_ctl -D "$PGD" -w stop -m fast >/dev/null
done < <(if [ -n "$CONFIGS" ]; then cat "$CONFIGS"; else default_configs; fi)
