#!/bin/bash
# wait events during big.sql, 16 clients, stock fdatasync
export PGHOST=/tmp PGDATABASE=postgres PGPORT=59120
B=~/pgaio/inst/stock/bin; D=/mnt/xfs/bigwait; rm -rf $D; cp -a --reflink=auto /mnt/xfs/golden-s20 $D
printf "port = 59120\nunix_socket_directories = '/tmp'\nlisten_addresses = ''\nshared_buffers = 512MB\nmax_wal_size = 8GB\ncheckpoint_timeout = 60min\nmax_connections = 200\nwal_buffers = 64MB\nautovacuum = off\nfull_page_writes = off\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D.log -w start >/dev/null
( for i in $(seq 1 500); do $B/psql -XAtc "SELECT coalesce(wait_event_type,'CPU')||':'||coalesce(wait_event,'running') FROM pg_stat_activity WHERE backend_type='client backend' AND query NOT LIKE '%pg_stat_activity%'"; sleep 0.02; done ) > /tmp/bigwait.txt &
tps=$($B/pgbench -n -f ~/pgaio/bench/big.sql -c 16 -j 16 -T 12 2>&1 | awk '/^tps/ {print $3}'); wait
echo "== stock, big.sql, 16 clients: $tps tps"
sort /tmp/bigwait.txt | uniq -c | sort -rn | awk -v n=$(wc -l < /tmp/bigwait.txt) '{printf "  %5.1f%%  %s\n", 100*$1/n, $2}' | head -8
echo "== CPU: $(nproc) vCPUs, load during run: $(cat /proc/loadavg)"
$B/pg_ctl -D $D -w stop -m fast >/dev/null; rm -rf $D $D.log
