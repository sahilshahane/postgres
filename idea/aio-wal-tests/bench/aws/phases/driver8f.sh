#!/bin/bash
S=$HOME/sahil/scratch; V="ssh -F $S/ssh_aws.cfg -o ConnectTimeout=60 pgaio-aws"
Q="$HOME/sahil/dbms-project/idea/aio-wal-tests/results-aws/08f-screening-quiesce"
r() { for i in 1 2 3 4 5; do timeout 120 "$@" && return 0; sleep 20; done; return 1; }
r scp -F $S/ssh_aws.cfg /home/neel/sahil/dbms-project/idea/aio-wal-tests/bench/bench.sh $S/cfg_screen.txt $S/run_screen_q.sh pgaio-aws:pgaio/bench/ || { echo upload failed; exit 1; }
r $V 'chmod +x ~/pgaio/bench/run_screen_q.sh; rm -rf /mnt/xfs/b3; nohup ~/pgaio/bench/run_screen_q.sh > /dev/null 2>&1 < /dev/null & echo P8f started'
until r $V 'grep -q P8F_DONE ~/pgaio/results-aws-screen-q/log.txt' 2>/dev/null; do sleep 60; done
mkdir -p $Q
for f in cfg.txt raw.csv log.txt analysis.txt paired.csv tps.csv; do r scp -F $S/ssh_aws.cfg pgaio-aws:pgaio/results-aws-screen-q/$f $Q/; done
echo "P8f fetched $(date -u)"
