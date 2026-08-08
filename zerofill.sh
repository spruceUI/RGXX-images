#!/bin/bash
# Zero out free space inside an Anbernic image so it compresses well.
# Writes a file of zeros until each filesystem is full, then deletes it.
# Content is untouched -- only previously-deleted junk is overwritten.
set -uo pipefail

IMG="${1:?usage: zerofill.sh /path/to/image.IMG}"
[ -f "$IMG" ] || { echo "!! no such image: $IMG" >&2; exit 1; }

LOOP=""
MNT=/mnt/zf

cleanup() {
    set +e
    mountpoint -q "$MNT" && umount "$MNT"
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

echo "== attaching loop device =="
LOOP=$(losetup -Pf --show "$IMG")
echo "   $LOOP"
sleep 1

mkdir -p "$MNT"

# Only the four large data partitions. p2/p3/p4 are tiny boot/raw
# partitions -- not worth the risk or the time.
for part in 1 5 6 7; do
    DEV="${LOOP}p${part}"
    [ -b "$DEV" ] || { echo "-- p$part: no such device, skipping"; continue; }

    FSTYPE=$(blkid -s TYPE -o value "$DEV" 2>/dev/null || echo "")
    case "$FSTYPE" in
        ext2|ext3|ext4|vfat) ;;
        *) echo "-- p$part: type '$FSTYPE' not zeroable, skipping"; continue ;;
    esac

    echo
    echo "== p$part ($FSTYPE) =="
    if ! mount "$DEV" "$MNT" 2>/dev/null; then
        echo "   !! mount failed, skipping"
        continue
    fi

    BEFORE=$(df -h "$MNT" | awk 'NR==2{print $4}')
    echo "   free before: $BEFORE  -- writing zeros..."

    # Expected to end in ENOSPC; that is the success condition here.
    dd if=/dev/zero of="$MNT/.zerofill.tmp" bs=4M status=none 2>/dev/null
    sync

    WROTE=$(du -h "$MNT/.zerofill.tmp" 2>/dev/null | awk '{print $1}')
    rm -f "$MNT/.zerofill.tmp"
    sync

    AFTER=$(df -h "$MNT" | awk 'NR==2{print $4}')
    echo "   zeroed $WROTE, free after: $AFTER"

    umount "$MNT"
done

echo
echo "== detaching =="
sync
losetup -d "$LOOP"
LOOP=""
trap - EXIT
echo "DONE -- free space zeroed."
