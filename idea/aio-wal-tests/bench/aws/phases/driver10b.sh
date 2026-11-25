#!/bin/bash
S=$HOME/sahil/scratch; V="ssh -F $S/ssh_aws.cfg -o ConnectTimeout=60 pgaio-aws"
BD=/home/neel/sahil/dbms-project/idea/aio-wal-tests/bench
Q="$HOME/sahil/dbms-project/idea/aio-wal-tests/results-aws/10-standard"
r() { for i in 1 2 3 4 5; do timeout 300 "$@" && return 0; sleep 20; done; return 1; }
r scp -F $S/ssh_aws.cfg $BD/bench.sh $BD/bbconf.py $BD/copy.sql $BD/make_golden_std.sh $S/cfg_std.txt $S/run_std.sh $S/setup_std.sh pgaio-aws:pgaio/bench/ || { echo upload failed; exit 1; }
r $V 'chmod +x ~/pgaio/bench/*.sh; nohup bash -c "rm -rf /mnt/xfs/b3 && ~/pgaio/bench/run_std.sh" > /dev/null 2>&1 < /dev/null & echo P10 started'
until r $V 'grep -q P10_DONE ~/pgaio/results-aws-std/progress.txt' 2>/dev/null; do sleep 120; done
mkdir -p $Q; r scp -F $S/ssh_aws.cfg -r 'pgaio-aws:pgaio/results-aws-std/*' $Q/; r scp -F $S/ssh_aws.cfg pgaio-aws:pgaio/setup_std.log $Q/
echo "P10 fetched $(date -u)"
