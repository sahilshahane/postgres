#!/bin/bash
R=~/pgaio/results-aws-big; mkdir -p $R
sed "s|INST|$HOME/pgaio/inst|" ~/pgaio/bench/cfg_big.txt > $R/cfg.txt
# WAL bytes per big.sql commit (stock, 200 commits)
B=~/pgaio/inst/stock/bin; D=/mnt/xfs/walsize; rm -rf $D; cp -a --reflink=auto /mnt/xfs/golden-s20 $D
printf "port = 59200\nunix_socket_directories = '/tmp'\nlisten_addresses = ''\nfull_page_writes = off\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D.log -w start >/dev/null
a=$(PGPORT=59200 $B/psql -h /tmp -XAtc "SELECT pg_current_wal_lsn()" postgres)
PGPORT=59200 $B/pgbench -h /tmp -n -f ~/pgaio/bench/big.sql -t 200 postgres >/dev/null 2>&1
b=$(PGPORT=59200 $B/psql -h /tmp -XAtc "SELECT pg_current_wal_lsn()" postgres)
PGPORT=59200 $B/psql -h /tmp -XAtc "SELECT 'wal_bytes_per_commit ' || (pg_wal_lsn_diff('$b','$a')/200)::bigint" postgres > $R/walsize.txt
$B/pg_ctl -D $D -w stop -m fast >/dev/null; rm -rf $D $D.log
CLIENTS="1 4 16" ROUNDS=6 SECONDS_=10 CANARY_MAX=6000 WORKLOAD=big WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden-s20 \
  bash ~/pgaio/bench/bench.sh $R/cfg.txt $R/raw.csv > $R/log.txt 2>&1
python3 ~/pgaio/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
echo BIG_DONE >> $R/log.txt
