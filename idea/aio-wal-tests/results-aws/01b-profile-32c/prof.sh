#!/bin/bash
# wait-event profile: stock fdatasync vs aio fds thr=256kB (if=16), 32 clients
export PGHOST=/tmp PGDATABASE=postgres
for cfg in "stock|stock|wal_sync_method = fdatasync" "aio|aio|wal_io_method = aio|io_method = io_uring|wal_sync_method = fdatasync|wal_io_max_inflight = 16"; do
  IFS='|' read -ra p <<< "$cfg"; name=${p[0]}; B=~/pgaio/inst/${p[1]}/bin; D=/mnt/xfs/prof-$name; PORT=59100
  rm -rf $D; cp -a --reflink=auto /mnt/xfs/golden-s20 $D
  printf "port = $PORT\nunix_socket_directories = '/tmp'\nlisten_addresses = ''\nshared_buffers = 512MB\nmax_wal_size = 8GB\ncheckpoint_timeout = 60min\nmax_connections = 200\nwal_buffers = 64MB\nautovacuum = off\nfull_page_writes = off\n" >> $D/postgresql.conf
  for kv in "${p[@]:2}"; do echo "$kv" >> $D/postgresql.conf; done
  $B/pg_ctl -D $D -l $D.log -w start >/dev/null; export PGPORT=$PORT
  $B/psql -XAtqc CHECKPOINT; $B/pgbench -N -c 32 -j 16 -T 3 >/dev/null 2>&1
  ( for i in $(seq 1 600); do $B/psql -XAtc "SELECT coalesce(wait_event_type,'CPU')||':'||coalesce(wait_event,'running') FROM pg_stat_activity WHERE backend_type='client backend' AND query NOT LIKE '%pg_stat_activity%'"; sleep 0.02; done ) > /tmp/prof-$name.txt &
  tps=$($B/pgbench -N -c 32 -j 16 -T 15 2>&1 | awk '/^tps/ {print $3}')
  wait
  echo "== $name: $tps tps; wait events of 32 backends (share of samples)"
  sort /tmp/prof-$name.txt | uniq -c | sort -rn | awk -v n=$(wc -l < /tmp/prof-$name.txt) '{printf "  %5.1f%%  %s\n", 100*$1/n, $2}' | head -8
  $B/pg_ctl -D $D -w stop -m fast >/dev/null; rm -rf $D $D.log
done
