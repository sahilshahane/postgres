#!/bin/bash
# sweep.sh CAMPAIGN BENCH WORKLOAD "SB1 SB2 .." "POLICY1 .." REPS
#   Runs every (rep, shared_buffers, policy) combination.  Policies are
#   interleaved inside each (rep, size) so slow drift on the shared machine
#   does not line up with one policy.  Finished runs are skipped, so the
#   sweep can simply be restarted after an interruption.
set -uo pipefail
. "$(dirname "$0")/env.sh"
CAMPAIGN=$1 BENCH=$2 WL=$3 SBS=$4 POLICIES=$5 REPS=$6
for rep in $(seq 1 $REPS); do
  for sb in $SBS; do
    for p in $(echo $POLICIES | tr ' ' '\n' | shuf --random-source=<(yes $rep$sb)); do
      out=$RESULTS/$CAMPAIGN/$WL/$p/sb$sb/rep$rep
      echo "[$(date +%T)] $WL $p sb=$sb rep=$rep"
      "$(dirname "$0")/run_one.sh" $BENCH $WL $p $sb $rep $out || echo "FAILED $out"
    done
  done
done
