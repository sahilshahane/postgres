#!/bin/bash
# phase 10 setup on the VM: sysbench, JDK 21, BenchBase (postgres profile), golden-std
set -e; P=$HOME/pgaio; L=$P/setup_std.log; exec > $L 2>&1
sudo DEBIAN_FRONTEND=noninteractive apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq sysbench openjdk-21-jdk-headless git
if [ ! -f $HOME/benchbase/benchbase.jar ]; then
  rm -rf $HOME/bb-src; git clone --depth 1 https://github.com/cmu-db/benchbase.git $HOME/bb-src
  (cd $HOME/bb-src && ./mvnw -q clean package -P postgres -DskipTests)
  tar xzf $HOME/bb-src/target/benchbase-postgres.tgz -C $HOME
  rm -rf $HOME/benchbase; mv $HOME/benchbase-postgres $HOME/benchbase
fi
rm -rf /mnt/xfs/golden-std
bash $P/bench/make_golden_std.sh $P/inst/stock4 /mnt/xfs/golden4 /mnt/xfs/golden-std
df -h /mnt/xfs; du -sh /mnt/xfs/golden-std
echo SETUP_DONE
