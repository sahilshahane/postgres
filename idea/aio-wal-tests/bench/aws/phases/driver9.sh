#!/bin/bash
S=$HOME/sahil/scratch; V="ssh -F $S/ssh_aws.cfg -o ConnectTimeout=60 pgaio-aws"
Q="$HOME/sahil/dbms-project/idea/aio-wal-tests/results-aws/09-tuned-stock"
r() { for i in 1 2 3 4 5; do timeout 120 "$@" && return 0; sleep 20; done; return 1; }
r scp -F $S/ssh_aws.cfg /home/neel/sahil/dbms-project/idea/aio-wal-tests/bench/bench.sh $S/cfg_tuned.txt $S/run_tuned.sh pgaio-aws:pgaio/bench/ || { echo upload failed; exit 1; }
r $V 'chmod +x ~/pgaio/bench/run_tuned.sh; rm -rf /mnt/xfs/b3; nohup ~/pgaio/bench/run_tuned.sh > /dev/null 2>&1 < /dev/null & echo P9 started'
until r $V 'grep -q P9_DONE ~/pgaio/results-aws-tuned/log.txt' 2>/dev/null; do sleep 60; done
mkdir -p $Q
for f in cfg.txt raw.csv log.txt analysis.txt paired.csv tps.csv msk_after.txt; do r scp -F $S/ssh_aws.cfg pgaio-aws:pgaio/results-aws-tuned/$f $Q/; done
echo "P9 fetched $(date -u)"
