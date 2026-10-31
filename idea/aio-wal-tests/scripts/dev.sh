#!/bin/bash
# Test block device for latency and power-loss experiments:
#   file -> loop (direct I/O) -> dm-delay -> dm-flakey -> ext4 at $TESTDISK_DIR/mnt
# Only ever touches the image file below; no real disk is used.
#
# Run as root (sudo -E keeps TESTDISK_DIR):
#   dev.sh setup DELAY_MS FLUSH_DELAY_MS  create + mount, owned by $OWNER
#   dev.sh writethrough                   report write-through cache (cloud-disk
#                                         model: no cache flushes needed)
#   dev.sh powercut                       drop all writes from now on
#   dev.sh restore                        unmount (dirty page cache is lost),
#                                         writes on again, remount
#   dev.sh teardown                       unmount, remove devices and image
set -e
TESTDISK_DIR=${TESTDISK_DIR:-/tmp/pg-aio-testdisk}
IMG=$TESTDISK_DIR/disk.img; MNT=$TESTDISK_DIR/mnt
OWNER=${OWNER:-${SUDO_USER:-$USER}}
SIZE=${SIZE:-6G}

flakey_table() {  # $1 = up|down
  local n=$(blockdev --getsz /dev/mapper/pgdelay)
  if [ "$1" = up ]; then echo "0 $n flakey /dev/mapper/pgdelay 0 86400 0"
  else echo "0 $n flakey /dev/mapper/pgdelay 0 0 86400 1 drop_writes"; fi
}

case $1 in
setup)
  D=${2:-0}; F=${3:-$D}
  modprobe dm_delay; modprobe dm_flakey
  mkdir -p "$TESTDISK_DIR"
  truncate -s "$SIZE" "$IMG"
  LOOP=$(losetup --direct-io=on --show -f "$IMG")
  n=$(blockdev --getsz "$LOOP")
  # dm-delay groups: reads, writes, flushes
  dmsetup create pgdelay --table "0 $n delay $LOOP 0 $D $LOOP 0 $D $LOOP 0 $F"
  dmsetup create pgflakey --table "$(flakey_table up)"
  mkfs.ext4 -q -F /dev/mapper/pgflakey
  mkdir -p "$MNT"; mount /dev/mapper/pgflakey "$MNT"; chown "$OWNER" "$MNT"
  echo "ready: $LOOP delay=${D}ms flush_delay=${F}ms mounted at $MNT"
  ;;
writethrough)
  LOOP=$(losetup -j "$IMG" | cut -d: -f1 | xargs -n1 basename)
  for d in $LOOP $(basename "$(readlink -f /dev/mapper/pgdelay)") \
           $(basename "$(readlink -f /dev/mapper/pgflakey)"); do
    echo "write through" > /sys/block/$d/queue/write_cache
  done
  ;;
powercut)
  # in-flight and future writes are silently dropped, like losing power
  dmsetup load pgflakey --table "$(flakey_table down)"
  dmsetup suspend --noflush pgflakey
  dmsetup resume pgflakey
  ;;
restore)
  # unmounting writes back dirty page cache -> dropped (lost with the power)
  umount "$MNT"
  dmsetup load pgflakey --table "$(flakey_table up)"
  dmsetup suspend pgflakey; dmsetup resume pgflakey
  echo 3 > /proc/sys/vm/drop_caches
  mount /dev/mapper/pgflakey "$MNT"
  ;;
teardown)
  umount "$MNT" 2>/dev/null || true
  dmsetup remove pgflakey 2>/dev/null || true
  dmsetup remove pgdelay 2>/dev/null || true
  for l in $(losetup -j "$IMG" | cut -d: -f1); do losetup -d "$l"; done
  rm -f "$IMG"
  ;;
*)
  echo "usage: $0 setup DELAY_MS [FLUSH_DELAY_MS] | writethrough | powercut | restore | teardown" >&2
  exit 1
  ;;
esac
