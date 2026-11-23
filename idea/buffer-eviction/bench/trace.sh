#!/bin/bash
# trace.sh CAMPAIGN BENCH WORKLOAD SB "CACHE_PAGES,..."
#   Records a buffer-access trace of one run (clock policy; the stream of
#   requested pages does not depend on the policy), then replays it offline:
#   evictsim (our policies + LRU + Belady OPT) and libCacheSim (ARC, LIRS,
#   CLOCK-Pro, 2Q, ...), both on the full trace and without ring accesses.
set -euo pipefail
. "$(dirname "$0")/env.sh"
CAMPAIGN=$1 BENCH=$2 WL=$3 SB=$4 SIZES=$5
OUT=$RESULTS/$CAMPAIGN/$WL
mkdir -p $OUT
if [ ! -f $OUT/run/done ]; then
  rm -rf $OUT/trace; mkdir -p $OUT/trace
  EXTRA_PG_OPTS="-c buffer_trace_directory=$OUT/trace" TIME=${TIME:-60} \
    "$(dirname "$0")/run_one.sh" $BENCH $WL clock $SB 1 $OUT/run
fi
cd $OUT
[ -f trace.bin ] || { $SIM merge trace.bin trace/*.bin; rm -rf trace; }
[ -f trace.noring.bin ] || $SIM filter trace.bin trace.noring.bin
for t in trace trace.noring; do
  $SIM stats $t.bin > $t.stats.txt
  [ -f $t.evictsim.csv ] || $SIM sweep $t.bin $SIZES > $t.evictsim.csv
  [ -f $t.oracleGeneral ] || $SIM oracle $t.bin $t.oracleGeneral > /dev/null
  : > $t.libcachesim.txt
  for algo in lru clock fifo arc CAR clockpro lirs twoq lru-k mq tinyLFU wtinyLFU lecar sieve s3fifo belady; do
    for pages in $(echo $SIZES | tr ',' ' '); do
      echo "algo=$algo pages=$pages $($CACHESIM $t.oracleGeneral oracleGeneral $algo $((pages * 8192)) 2>&1 | grep -i 'miss ratio' | tail -1)" >> $t.libcachesim.txt
    done
  done
  rm -f $t.oracleGeneral
done
echo "traced $WL: $(cat trace.stats.txt)"
