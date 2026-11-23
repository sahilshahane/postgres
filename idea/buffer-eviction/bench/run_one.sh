#!/bin/bash
# run_one.sh BENCH WORKLOAD POLICY SHARED_BUFFERS REP OUTDIR
#   One measured run from a pristine copy of the dataset, cold cache.
#   WORKLOAD selects the BenchBase mix (tpcc | ycsb-b | ycsb-e | tpch).
set -euo pipefail
. "$(dirname "$0")/env.sh"
BENCH=$1 WL=$2 POLICY=$3 SB=$4 REP=$5 OUT=$6
TERMINALS=${TERMINALS:-16} WARMUP=${WARMUP:-30} TIME=${TIME:-120}
[ -f $OUT/done ] && { echo "skip $OUT"; exit 0; }
rm -rf $OUT; mkdir -p $OUT
RUN=$DATA/$BENCH-run

# fresh copy of the pristine data directory
t0=$(date +%s)
rm -rf $RUN; cp -a $DATA/$BENCH-pristine $RUN
echo "include '$CONFIGS/postgresql.bench.conf'" >> $RUN/postgresql.conf
copy_s=$(( $(date +%s) - t0 ))

pg_ctl -D $RUN -l $OUT/postgres.log -w -t 300 start \
  -o "-c shared_buffers=$SB -c buffer_eviction_policy=$POLICY ${EXTRA_PG_OPTS:-}" > /dev/null
trap 'pg_ctl -D $RUN -w -m fast stop >/dev/null 2>&1 || true' EXIT
# never trust the command line: check what the server says it runs
grep -q "buffer eviction policy: $POLICY," $OUT/postgres.log || { echo "policy not active"; exit 1; }

# BenchBase config for this workload
case $WL in
  tpcc)   W="" ;;
  ycsb-b) W="95,0,0,5,0,0" ;;     # YCSB-B: 95% read, 5% update
  ycsb-e) W="0,5,95,0,0,0" ;;     # YCSB-E: 95% short scans, 5% insert
  tpch)   W="" ;;
esac
SF=$(cat $CONFIGS/$BENCH-sf)
if [ $BENCH = tpch ]; then
  cp $CONFIGS/tpch-load.xml $OUT/benchbase.xml
else
  sed -e "s/__SF__/$SF/" -e "s/__TERMINALS__/$TERMINALS/" -e "s/__WARMUP__/$WARMUP/" \
      -e "s/__TIME__/$TIME/" -e "s/__WEIGHTS__/$W/" $CONFIGS/$BENCH.xml > $OUT/benchbase.xml
fi

reset_stats() {
  psql -d benchbase -qAt -c "SELECT pg_stat_reset()" -c "SELECT pg_stat_reset_shared('io')" \
       -c "SELECT pg_buffer_eviction_stats_reset()" > /dev/null
}

# 1 Hz sampler of what active client backends wait on (lock contention, I/O)
( echo "ts,wait_event_type,wait_event,n"
  while true; do
    psql -d postgres -qAt -F, -c "SELECT extract(epoch from now())::int, coalesce(wait_event_type,'CPU'), coalesce(wait_event,'CPU'), count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND state='active' AND pid<>pg_backend_pid() GROUP BY 2,3" 2>/dev/null || true
    sleep 1
  done ) > $OUT/waits.csv &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null || true; pg_ctl -D $RUN -w -m fast stop >/dev/null 2>&1 || true' EXIT

t1=$(date +%s.%N)
if [ $BENCH = tpch ]; then
  # pass 1 warms the cache, pass 2 (all 22 queries, serial) is measured
  ( cd $BB && $JAVA -jar benchbase.jar -b tpch -c $OUT/benchbase.xml --execute=true -d $OUT/warm ) > $OUT/benchbase-warm.log 2>&1
  reset_stats
  t1=$(date +%s.%N)
  ( cd $BB && $JAVA -jar benchbase.jar -b tpch -c $OUT/benchbase.xml --execute=true -d $OUT/benchbase ) > $OUT/benchbase.log 2>&1
else
  ( cd $BB && $JAVA -jar benchbase.jar -b $BENCH -c $OUT/benchbase.xml --execute=true -d $OUT/benchbase ) > $OUT/benchbase.log 2>&1 &
  BBPID=$!
  sleep $WARMUP; reset_stats
  wait $BBPID
fi
elapsed=$(echo "$(date +%s.%N) - $t1" | bc)
sleep 2   # let backends flush their pgstat counters

psql -d benchbase -qAt -F, -c "SELECT blks_hit, blks_read, xact_commit, xact_rollback, blk_read_time FROM pg_stat_database WHERE datname='benchbase'" > $OUT/pg_stat_database.csv
psql -d benchbase -qAt -F, -c "SELECT backend_type, object, context, coalesce(reads,0), coalesce(hits,0), coalesce(evictions,0), coalesce(reuses,0), coalesce(writes,0), coalesce(read_time,0) FROM pg_stat_io WHERE object='relation'" > $OUT/pg_stat_io.csv
psql -d benchbase -qAt -F, -c "SELECT * FROM pg_buffer_eviction_stats()" > $OUT/eviction_stats.csv
cat > $OUT/run.json <<JSON
{"bench":"$BENCH","workload":"$WL","policy":"$POLICY","shared_buffers":"$SB","rep":$REP,
 "terminals":$TERMINALS,"warmup_s":$WARMUP,"time_s":$TIME,"scalefactor":"$SF",
 "elapsed_s":$elapsed,"copy_s":$copy_s,"host":"$(hostname)","started":"$(date -Is -d @${t0})",
 "loadavg_end":"$(cut -d' ' -f1-3 /proc/loadavg)"}
JSON
kill $SAMPLER 2>/dev/null || true
pg_ctl -D $RUN -w -m fast stop > /dev/null
trap - EXIT
touch $OUT/done
echo "done $OUT ($(cat $OUT/pg_stat_database.csv))"
