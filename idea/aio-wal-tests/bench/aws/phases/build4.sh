#!/bin/bash
# stock and aio with 4 kB WAL pages, plus a golden cluster made with them
P=$HOME/pgaio
for v in stock aio; do
  ( cd $P/src/$v && meson setup build4 --buildtype=release -Dliburing=enabled -Dcassert=false -Dwal_blocksize=4 \
       --prefix=$P/inst/${v}4 > /dev/null && ninja -C build4 -j4 install > /dev/null ) &
done
wait
for v in stock aio; do $P/inst/${v}4/bin/pg_controldata --help >/dev/null 2>&1 || { echo "build $v failed"; exit 1; }; done
rm -rf /mnt/xfs/golden4; bash $P/bench/make_golden.sh $P/inst/stock4 /mnt/xfs/golden4
$P/inst/stock4/bin/pg_controldata /mnt/xfs/golden4 | grep -i "WAL block"
echo BUILD4_DONE
