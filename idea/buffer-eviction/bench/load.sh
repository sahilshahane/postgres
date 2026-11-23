#!/bin/bash
# load.sh BENCH SCALEFACTOR
#   Creates the pristine cluster $DATA/<bench>-pristine with the benchmark
#   data loaded by BenchBase, vacuumed, analyzed and checkpointed.  Every
#   measured run starts from a copy of this directory.
set -euo pipefail
. "$(dirname "$0")/env.sh"
BENCH=$1 SF=$2
PRISTINE=$DATA/$BENCH-pristine
LOG=$R/logs/load-$BENCH.log
mkdir -p $R/logs
[ -d $PRISTINE ] && { echo "$PRISTINE exists; remove it to reload"; exit 1; }

initdb -D $PRISTINE -A trust -U neel >$LOG 2>&1
# load with buffered I/O and a big cache (data files are identical either way)
pg_ctl -D $PRISTINE -l $R/logs/load-$BENCH-server.log -w start \
  -o "-c port=$PORT -c shared_buffers=2GB -c synchronous_commit=off -c wal_level=minimal -c max_wal_senders=0 -c max_wal_size=16GB -c autovacuum=off" >>$LOG
psql -d postgres -qc "CREATE ROLE admin SUPERUSER LOGIN PASSWORD 'password'" -c "CREATE DATABASE benchbase OWNER admin"

echo $SF > $CONFIGS/$BENCH-sf
CFG=$CONFIGS/$BENCH-load.xml
if [ $BENCH = tpch ]; then
  sed -e "s#localhost:5432#localhost:$PORT#" -e "s#<scalefactor>[^<]*<#<scalefactor>$SF<#" \
      -e "s#TRANSACTION_SERIALIZABLE#TRANSACTION_READ_COMMITTED#" \
      $BB/config/postgres/sample_tpch_config.xml > $CFG
else
  sed -e "s/__SF__/$SF/" -e "s/__TERMINALS__/1/" -e "s/__WARMUP__/0/" -e "s/__TIME__/10/" \
      -e "s/__WEIGHTS__/100,0,0,0,0,0/" $CONFIGS/$BENCH.xml > $CFG
fi
( cd $BB && $JAVA -jar benchbase.jar -b $BENCH -c $CFG --create=true --load=true --execute=false ) >>$LOG 2>&1
psql -d benchbase -qc "VACUUM (ANALYZE, FREEZE)" -c "CHECKPOINT"
psql -d benchbase -At -F, -c "SELECT 'database', pg_database_size('benchbase')" \
  -c "SELECT c.relname, pg_relation_size(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','i') ORDER BY 2 DESC" \
  > $CONFIGS/$BENCH-sizes.csv
pg_ctl -D $PRISTINE -w stop >>$LOG
echo "loaded $BENCH sf=$SF: $(head -1 $CONFIGS/$BENCH-sizes.csv | cut -d, -f2 | awk '{printf "%.2f GB", $1/1073741824}')"
