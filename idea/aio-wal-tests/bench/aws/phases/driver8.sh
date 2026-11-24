#!/bin/bash
S=$HOME/sahil/scratch; V="ssh -F $S/ssh_aws.cfg -o ConnectTimeout=60 pgaio-aws"
Q="$HOME/sahil/dbms-project/idea/aio-wal-tests/results-aws/08b-split-writes"
r() { for i in 1 2 3 4 5; do timeout 120 "$@" && return 0; sleep 20; done; return 1; }
r scp -F $S/ssh_aws.cfg $S/split_src.tgz pgaio-aws:pgaio/ && r scp -F $S/ssh_aws.cfg $S/cfg_split.txt $S/run_split.sh pgaio-aws:pgaio/bench/ || { echo upload failed; exit 1; }
r $V 'chmod +x ~/pgaio/bench/run_split.sh; rm -rf /mnt/xfs/b3; nohup ~/pgaio/bench/run_split.sh > /dev/null 2>&1 < /dev/null & echo P8 started'
until r $V 'grep -qE "P8_DONE|BUILD_FAILED|GUC_MISSING" ~/pgaio/results-aws-split/log.txt' 2>/dev/null; do sleep 60; done
mkdir -p $Q
for f in cfg.txt raw.csv log.txt analysis.txt paired.csv tps.csv build.log; do r scp -F $S/ssh_aws.cfg pgaio-aws:pgaio/results-aws-split/$f $Q/; done
echo "P8 fetched $(date -u)"
