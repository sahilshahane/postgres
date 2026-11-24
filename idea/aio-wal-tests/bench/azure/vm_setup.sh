#!/bin/bash
# Run on the Azure VM after pack.sh.  Installs build deps, formats the data
# disk as XFS (reflink) at /mnt/xfs, builds stock and aio, creates the golden
# cluster (make_golden.sh), and runs the fio queue-depth check.
#   usage: vm_setup.sh /dev/<data disk>      (find it with: lsblk)
# The disk is WIPED.  Re-running skips steps that are already done.
set -e
DISK=$1; P=$HOME/pgaio
[ -b "$DISK" ] || { echo "usage: $0 /dev/<data disk>  (see lsblk)" >&2; exit 1; }

sudo apt-get update -q
sudo apt-get install -yq build-essential meson ninja-build pkg-config flex bison \
  libreadline-dev zlib1g-dev libicu-dev liburing-dev fio xfsprogs python3

if ! mountpoint -q /mnt/xfs; then
  sudo mkfs.xfs -f -m reflink=1 "$DISK"
  sudo mkdir -p /mnt/xfs && sudo mount -o noatime "$DISK" /mnt/xfs
  sudo chown "$USER" /mnt/xfs
fi

for v in stock aio; do
  [ -x "$P/inst/$v/bin/postgres" ] && continue
  rm -rf "$P/src/$v"; mkdir -p "$P/src/$v"; tar xzf "$P/$v.tgz" -C "$P/src/$v"
  (cd "$P/src/$v" &&
   meson setup build --prefix="$P/inst/$v" --buildtype=release \
         -Dliburing=enabled -Dcassert=false >/dev/null &&
   ninja -C build install >/dev/null)
  echo "built $v"
done

[ -d /mnt/xfs/golden-s20 ] || bash "$P/bench/make_golden.sh" "$P/inst/stock" /mnt/xfs/golden-s20

echo; echo "== fio: durable 8k writes, QD1 vs QD16 (AIO can win only if QD16 >> QD1)"
for qd in 1 16; do
  fio --name=qd$qd --filename=/mnt/xfs/fio.test --size=1G --bs=8k --rw=write \
      --ioengine=io_uring --direct=1 --sync=dsync --iodepth=$qd \
      --runtime=15 --time_based --group_reporting \
    | awk -v qd=$qd '/IOPS=/ {print "QD" qd ": " $0} /clat \(usec\).*avg/ {print "   " $0}'
done
rm -f /mnt/xfs/fio.test

echo; echo "== canary (mean us per 8k O_DSYNC write); set CANARY_MAX ~3x this"
t0=$(date +%s%N); dd if=/dev/zero of=/mnt/xfs/canary bs=8k count=200 oflag=dsync 2>/dev/null
echo $(( ($(date +%s%N) - t0) / 200000 ))
