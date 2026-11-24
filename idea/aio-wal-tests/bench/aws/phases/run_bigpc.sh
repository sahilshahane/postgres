#!/bin/bash
P=$HOME/pgaio; R=$P/results-aws-bigpc; mkdir -p $R; G=/mnt/xfs/golden4; I=$P/inst/stock4/bin
# add the per-client tables to the 4 kB golden cluster (as make_golden.sh now does)
$I/pg_ctl -D $G -o "-p 58499 -k /tmp -c listen_addresses=" -w -l /tmp/g4.log start > /dev/null
$I/psql -h /tmp -p 58499 -XAq postgres -c "CREATE TABLE IF NOT EXISTS bigc (id int, pad text)" \
  -c "DO \$\$ BEGIN FOR i IN 0..127 LOOP EXECUTE format('CREATE TABLE IF NOT EXISTS big_%s () INHERITS (bigc)', i); END LOOP; END \$\$" \
  -c "VACUUM ANALYZE" -c CHECKPOINT > $R/golden.log 2>&1
$I/pg_ctl -D $G -w stop > /dev/null
sed "s|INST|$P/inst|" $P/bench/cfg_bigpc.txt > $R/cfg.txt
CLIENTS="1 4 16 32 64" ROUNDS=6 SECONDS_=10 CANARY_MAX=6000 WORKLOAD=bigpc WORKDIR=/mnt/xfs/b3 GOLDEN=$G \
  bash $P/bench/bench.sh $R/cfg.txt $R/raw.csv > $R/log.txt 2>&1
python3 $P/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
echo P7_DONE >> $R/log.txt
