#!/bin/bash
# waits for phase 4 on the VM, fetches it, starts phase 5, waits, fetches it
S=$HOME/sahil/scratch; V="ssh -F $S/ssh_aws.cfg -o ConnectTimeout=60 pgaio-aws"
Q="$HOME/sahil/dbms-project/idea/aio-wal-tests/results-aws"
r() { for i in 1 2 3 4 5; do timeout 120 "$@" && return 0; sleep 20; done; return 1; }
until r $V 'grep -q P4_DONE ~/pgaio/results-aws-4k/log.txt' 2>/dev/null; do sleep 60; done
mkdir -p $Q/04-4k-pages
for f in cfg.txt raw.csv log.txt analysis.txt paired.csv tps.csv; do r scp -F $S/ssh_aws.cfg pgaio-aws:pgaio/results-aws-4k/$f $Q/04-4k-pages/; done
echo "P4 fetched $(date -u)"
r scp -F $S/ssh_aws.cfg $S/align_src.tgz pgaio-aws:pgaio/ && r scp -F $S/ssh_aws.cfg $S/cfg_align.txt pgaio-aws:pgaio/bench/ && r scp -F $S/ssh_aws.cfg $S/run_align.sh pgaio-aws:pgaio/bench/ || { echo upload failed; exit 1; }
r $V 'chmod +x ~/pgaio/bench/run_align.sh; rm -rf /mnt/xfs/b3; nohup ~/pgaio/bench/run_align.sh > /dev/null 2>&1 < /dev/null & echo P5 started'
until r $V 'grep -qE "P5_DONE|BUILD_FAILED|GUC_MISSING" ~/pgaio/results-aws-align/log.txt' 2>/dev/null; do sleep 60; done
mkdir -p $Q/05-page-align
for f in cfg.txt raw.csv log.txt analysis.txt paired.csv tps.csv build.log; do r scp -F $S/ssh_aws.cfg pgaio-aws:pgaio/results-aws-align/$f $Q/05-page-align/; done
echo "P5 fetched $(date -u)"; tail -3 $Q/05-page-align/log.txt
