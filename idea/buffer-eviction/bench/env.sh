# Common paths for the buffer-eviction benchmarks (sourced by all scripts).
R=/home/neel/postgres_sahil
PGBIN=$R/install/release/bin
BB=$R/tools/benchbase/target/benchbase-postgres
JAVA=/usr/lib/jvm/java-21-openjdk-amd64/bin/java
SIM=$R/tools/evictsim/evictsim
CACHESIM=$R/tools/libCacheSim/_build/bin/cachesim
PORT=5440
DATA=$R/data
RESULTS=$R/bench/results
CONFIGS=$R/bench/configs
export PATH=$PGBIN:$PATH
export PGPORT=$PORT PGHOST=localhost PGUSER=neel
