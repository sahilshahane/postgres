#!/bin/bash
S=$HOME/sahil/scratch; V="ssh -F $S/ssh_aws.cfg -o ConnectTimeout=60 pgaio-aws"
Q="$HOME/sahil/dbms-project/idea/aio-wal-tests/results-aws/08d-threshold-256k"
r() { for i in 1 2 3 4 5; do timeout 120 "$@" && return 0; sleep 20; done; return 1; }
r scp -F $S/ssh_aws.cfg $S/cfg_thr_big.txt $S/cfg_thr_small.txt $S/run_thr.sh pgaio-aws:pgaio/bench/ || { echo upload failed; exit 1; }
r $V 'chmod +x ~/pgaio/bench/run_thr.sh; rm -rf /mnt/xfs/b3; nohup ~/pgaio/bench/run_thr.sh > /dev/null 2>&1 < /dev/null & echo P8d started'
until r $V 'grep -q P8D_DONE ~/pgaio/results-aws-thr-small/log.txt' 2>/dev/null; do sleep 60; done
for w in big small; do mkdir -p $Q/$w
  for f in cfg.txt raw.csv log.txt analysis.txt paired.csv tps.csv; do r scp -F $S/ssh_aws.cfg pgaio-aws:pgaio/results-aws-thr-$w/$f $Q/$w/; done
done
echo "P8d fetched $(date -u)"
