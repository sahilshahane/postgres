#!/bin/bash
# wait for phase 10, fetch it, then run phase 11 and fetch it
S=$HOME/sahil/scratch; V="ssh -F $S/ssh_aws.cfg -o ConnectTimeout=60 pgaio-aws"
BD=$HOME/sahil/dbms-project/idea/aio-wal-tests/bench; RA=$HOME/sahil/dbms-project/idea/aio-wal-tests/results-aws
r() { for i in 1 2 3 4 5; do timeout 300 "$@" && return 0; sleep 20; done; return 1; }
until r $V 'grep -q P10_DONE ~/pgaio/results-aws-std/progress.txt' 2>/dev/null; do sleep 120; done
mkdir -p $RA/10-standard; r scp -F $S/ssh_aws.cfg -r 'pgaio-aws:pgaio/results-aws-std/*' $RA/10-standard/; r scp -F $S/ssh_aws.cfg pgaio-aws:pgaio/setup_std.log $RA/10-standard/
echo "P10 fetched $(date -u)"
r scp -F $S/ssh_aws.cfg $BD/bench.sh $S/cfg_final.txt $S/run_final.sh pgaio-aws:pgaio/bench/ || { echo upload failed; exit 1; }
r $V 'chmod +x ~/pgaio/bench/run_final.sh; rm -rf /mnt/xfs/b3; nohup ~/pgaio/bench/run_final.sh > /dev/null 2>&1 < /dev/null & echo P11 started'
until r $V 'grep -q P11_DONE ~/pgaio/results-aws-final/progress.txt' 2>/dev/null; do sleep 120; done
mkdir -p $RA/11-final; r scp -F $S/ssh_aws.cfg -r 'pgaio-aws:pgaio/results-aws-final/*' $RA/11-final/
echo "P11 fetched $(date -u)"
