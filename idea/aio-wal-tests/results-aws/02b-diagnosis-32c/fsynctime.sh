#!/bin/bash
# voluntary context switches of client backends per committed transaction, 32 clients
export PGHOST=/tmp PGDATABASE=postgres
C=${C:-32}
for cfg in "stock|stock|wal_sync_method = fdatasync" "aio|aio|wal_io_method = aio|io_method = io_uring|wal_sync_method = fdatasync|wal_io_max_inflight = 16"; do
  IFS='|' read -ra p <<< "$cfg"; name=${p[0]}; B=~/pgaio/inst/${p[1]}/bin; D=/mnt/xfs/ctx-$name; PORT=59110
  rm -rf $D; cp -a --reflink=auto /mnt/xfs/golden-s20 $D
  printf "port = $PORT\nunix_socket_directories = '/tmp'\nlisten_addresses = ''\nshared_buffers = 512MB\nmax_wal_size = 8GB\ncheckpoint_timeout = 60min\nmax_connections = 200\nwal_buffers = 64MB\nautovacuum = off\nfull_page_writes = off\ntrack_wal_io_timing = on\n" >> $D/postgresql.conf
  for kv in "${p[@]:2}"; do echo "$kv" >> $D/postgresql.conf; done
  $B/pg_ctl -D $D -l $D.log -w start >/dev/null; export PGPORT=$PORT
  $B/psql -XAtqc CHECKPOINT; $B/pgbench -N -c $C -j 16 -T 3 >/dev/null 2>&1
  pm=$(head -1 $D/postmaster.pid)
  $B/pgbench -N -c $C -j 16 -T 15 > /tmp/ctx-$name.out 2>&1 &
  sleep 2   # backends connected
  snap() { for c in $(pgrep -P $pm); do awk '/^voluntary_ctxt_switches/ {print $2}' /proc/$c/status 2>/dev/null; done | awk '{s+=$1} END {print s}'; }
  t0=$(date +%s.%N); a=$(snap); x0=$($B/psql -XAtc "SELECT xact_commit FROM pg_stat_database WHERE datname='postgres'"); f0=$($B/psql -XAtc "SELECT sum(fsyncs) FROM pg_stat_io WHERE object='wal'"); t0=$($B/psql -XAtc "SELECT sum(fsync_time) FROM pg_stat_io WHERE object='wal'")
  sleep 10
  b=$(snap); x1=$($B/psql -XAtc "SELECT xact_commit FROM pg_stat_database WHERE datname='postgres'"); f1=$($B/psql -XAtc "SELECT sum(fsyncs) FROM pg_stat_io WHERE object='wal'"); t1=$($B/psql -XAtc "SELECT sum(fsync_time) FROM pg_stat_io WHERE object='wal'")
  wait
  echo "$name: $(awk '/^tps/ {print $3}' /tmp/ctx-$name.out) tps; $((b-a)) voluntary switches / $((x1-x0)) commits = $(python3 -c "print(round(($b-$a)/max(1,$x1-$x0),2))") per commit; $((f1-f0)) WAL fsyncs = $(python3 -c "print(round(($x1-$x0)/max(1,$f1-$f0),2))") commits per fsync; avg fsync $(python3 -c "print(round(($t1-$t0)/max(1,$f1-$f0),3))") ms, cycle $(python3 -c "print(round(10000/max(1,$f1-$f0),3))") ms"
  $B/pg_ctl -D $D -w stop -m fast >/dev/null; rm -rf $D $D.log
done
