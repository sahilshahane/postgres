#!/bin/bash
S=$HOME/sahil/scratch; V="ssh -F $S/ssh_aws.cfg -o ConnectTimeout=60 pgaio-aws"
Q="$HOME/sahil/dbms-project/idea/aio-wal-tests/results-aws/08e-screening"
r() { for i in 1 2 3 4 5; do timeout 120 "$@" && return 0; sleep 20; done; return 1; }
r scp -F $S/ssh_aws.cfg $S/cfg_screen.txt $S/run_screen.sh pgaio-aws:pgaio/bench/ || { echo upload failed; exit 1; }
r $V 'chmod +x ~/pgaio/bench/run_screen.sh; rm -rf /mnt/xfs/b3; nohup ~/pgaio/bench/run_screen.sh > /dev/null 2>&1 < /dev/null & echo P8e started'
until r $V 'grep -q P8E_DONE ~/pgaio/results-aws-screen/log.txt' 2>/dev/null; do sleep 60; done
mkdir -p $Q
for f in cfg.txt raw.csv log.txt analysis.txt paired.csv tps.csv; do r scp -F $S/ssh_aws.cfg pgaio-aws:pgaio/results-aws-screen/$f $Q/; done
echo "P8e fetched $(date -u)"
