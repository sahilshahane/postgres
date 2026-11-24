#!/bin/bash
# Create the golden data directory that bench.sh reflink-copies for every
# config: pgbench scale 20 plus the "big" table of big.sql and the per-client
# tables big_0..big_127 (children of bigc) of bigpc.sql, vacuumed and
# checkpointed, so benchmark setup writes nothing.
#   usage: make_golden.sh STOCK_INSTALLDIR GOLDEN_DIR [SCALE]
set -e
I=$1; G=$2; SCALE=${3:-20}
[ -n "$G" ] || { echo "usage: $0 STOCK_INSTALLDIR GOLDEN_DIR [SCALE]" >&2; exit 1; }
[ -e "$G" ] && { echo "$G exists" >&2; exit 1; }
PORT=58499
"$I/bin/initdb" -D "$G" -A trust >/dev/null
"$I/bin/pg_ctl" -D "$G" -o "-p $PORT -k /tmp -c listen_addresses=" -w -l "$G.log" start >/dev/null
"$I/bin/pgbench" -h /tmp -p $PORT -i -s "$SCALE" -q postgres
"$I/bin/psql" -h /tmp -p $PORT -XAq postgres \
  -c "CREATE TABLE big (id int, pad text)" \
  -c "CREATE TABLE bigc (id int, pad text)" \
  -c "DO \$\$ BEGIN FOR i IN 0..127 LOOP EXECUTE format('CREATE TABLE big_%s () INHERITS (bigc)', i); END LOOP; END \$\$" \
  -c "VACUUM ANALYZE" -c CHECKPOINT
"$I/bin/pg_ctl" -D "$G" -w stop >/dev/null
rm -f "$G.log"
echo "golden cluster ready: $G (scale $SCALE)"
