#!/bin/bash
# Golden data directory for bench.sh's standard workloads: a reflink copy of
# GOLDEN_BASE (make_golden.sh) plus
#   BenchBase TPC-C (16 warehouses) and YCSB (1,000,000 records),
#   sysbench's sbtest1..8 (100,000 rows each), and the "bulk" table of copy.sql;
# vacuumed and checkpointed.
#   usage: make_golden_std.sh STOCK_INSTALLDIR GOLDEN_BASE GOLDEN_DIR
#   env: BB_HOME (~/benchbase)
set -e
I=$1; B=$2; G=$3; HERE=$(cd "$(dirname "$0")" && pwd); BB_HOME=${BB_HOME:-$HOME/benchbase}
[ -n "$G" ] || { echo "usage: $0 STOCK_INSTALLDIR GOLDEN_BASE GOLDEN_DIR" >&2; exit 1; }
[ -e "$G" ] && { echo "$G exists" >&2; exit 1; }
PORT=58499; export PGHOST=/tmp PGPORT=$PORT PGDATABASE=postgres
cp -a --reflink=auto "$B" "$G"
"$I/bin/pg_ctl" -D "$G" -o "-p $PORT -k /tmp -c listen_addresses=localhost -c max_connections=200 -c shared_buffers=1GB -c max_wal_size=8GB -c full_page_writes=off" \
  -w -l "$G.log" start >/dev/null
"$I/bin/psql" -XAqc "CREATE TABLE bulk (id int, pad text)"
sysbench oltp_write_only --db-driver=pgsql --pgsql-host=/tmp --pgsql-port=$PORT \
  --pgsql-user="$USER" --pgsql-db=postgres --tables=8 --table-size=100000 --threads=8 prepare
for b in tpcc:16 ycsb:1000; do
  python3 "$HERE/bbconf.py" "$BB_HOME" ${b%:*} "$G.$b.xml" $PORT 8 10 ${b#*:}
  (cd "$BB_HOME" && java -jar benchbase.jar -b ${b%:*} -c "$G.$b.xml" --create=true --load=true)
  rm -f "$G.$b.xml"
done
"$I/bin/psql" -XAq -c "VACUUM ANALYZE" -c CHECKPOINT
"$I/bin/psql" -XAtc "SELECT pg_size_pretty(pg_database_size('postgres'))"
"$I/bin/pg_ctl" -D "$G" -w stop >/dev/null
rm -f "$G.log"
echo "golden cluster ready: $G"
