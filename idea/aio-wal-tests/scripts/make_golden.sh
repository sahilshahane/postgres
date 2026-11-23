#!/bin/bash
# Create the saved benchmark dataset that bench.sh copies (GOLDEN=...).
# Built once with the stock binaries; the AIO fork uses the same on-disk
# format, so the same directory works for both builds.
#
# usage: make_golden.sh INSTALLDIR GOLDEN_DIR [SCALE]
#
# Contents: pgbench tables at SCALE (default 20) plus the empty "big" table
# used by WORKLOAD=big.  Shut down cleanly after VACUUM ANALYZE + CHECKPOINT.
set -e
INST=$1; G=$2; SCALE=${3:-20}; PORT=${PORT:-58399}
[ -n "$G" ] || { echo "usage: $0 INSTALLDIR GOLDEN_DIR [SCALE]" >&2; exit 1; }
[ -e "$G" ] && { echo "$G already exists; remove it first" >&2; exit 1; }
B=$INST/bin
export PGHOST=/tmp PGPORT=$PORT PGDATABASE=postgres

$B/initdb -D "$G" -A trust >/dev/null
$B/pg_ctl -D "$G" -l "$G.log" -o "-p $PORT -k /tmp -c listen_addresses=''" -w start >/dev/null
$B/pgbench -i -s "$SCALE" -q
$B/psql -XAtqc "CREATE TABLE big(id int, pad text)"
$B/psql -XAtqc "VACUUM ANALYZE"
$B/psql -XAtqc "CHECKPOINT"
$B/pg_ctl -D "$G" -w stop -m fast >/dev/null
rm -f "$G.log"

{
  echo "created:  $(date -Is)"
  echo "binaries: $INST ($($B/postgres --version))"
  echo "scale:    $SCALE"
  echo "size:     $(du -sh "$G" | cut -f1)"
} > "$G.info"
# checksum of the files so it can be verified later
( cd "$G" && find . -type f ! -name postmaster.opts -print0 | sort -z | xargs -0 sha256sum ) | sha256sum | cut -d' ' -f1 > "$G.sha256"
cat "$G.info"; echo "sha256:   $(cat "$G.sha256")"
