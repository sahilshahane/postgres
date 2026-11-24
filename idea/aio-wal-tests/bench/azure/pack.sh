#!/bin/bash
# Run locally, from anywhere inside the repo.  Packs stock (the upstream base
# commit) and aio (HEAD, the latest committed code) plus bench/ and tests/,
# and copies them to the VM.
#   usage: pack.sh azureuser@<VM_IP>
set -e
DEST=$1; [ -n "$DEST" ] || { echo "usage: $0 user@host" >&2; exit 1; }
ROOT=$(git rev-parse --show-toplevel); cd "$ROOT"
OUT=$(mktemp -d)
git archive --format=tar.gz -o "$OUT/stock.tgz" 126976a8ff   # upstream base
git archive --format=tar.gz -o "$OUT/aio.tgz"   HEAD         # latest committed code
tar czf "$OUT/scripts.tgz" -C idea/aio-wal-tests bench tests
ssh "$DEST" 'mkdir -p ~/pgaio'
scp "$OUT"/*.tgz "$DEST":~/pgaio/
rm -rf "$OUT"
echo "copied; now on the VM: tar xzf ~/pgaio/scripts.tgz -C ~/pgaio && bash ~/pgaio/bench/azure/vm_setup.sh /dev/<disk>"
