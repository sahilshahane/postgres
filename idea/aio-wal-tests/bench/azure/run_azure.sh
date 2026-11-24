#!/bin/bash
# Run on the VM after vm_setup.sh.  Paired bench3 run of cfg_azure.txt, then
# paired comparison of each config vs the stock config of its mode.
# WORKLOAD=big runs the large-transaction workload instead.  ~35-45 min with the defaults.
#   usage: CANARY_MAX=<us> run_azure.sh [TAG]
set -e
S=$HOME/pgaio/bench; TAG=${1:-azure}; R=$HOME/pgaio/results-$TAG
mkdir -p "$R"
sed "s|INST|$HOME/pgaio/inst|" "$S/azure/cfg_azure.txt" > "$R/cfg.txt"
CLIENTS=${CLIENTS:-"1 4 8 16 32 64"} ROUNDS=${ROUNDS:-6} SECONDS_=${SECONDS_:-5} \
CANARY_MAX=${CANARY_MAX:?set CANARY_MAX from vm_setup.sh output} WORKLOAD=${WORKLOAD:-pgbench} \
WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden-s20 \
  bash "$S/bench.sh" "$R/cfg.txt" "$R/raw.csv" | tee "$R/log.txt"
python3 "$S/analyze.py" "$R/cfg.txt" "$R/raw.csv" "$R"
echo "results in $R  (copy back: scp -r <vm>:$R .)"
