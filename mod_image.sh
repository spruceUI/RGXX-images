#!/bin/bash
# Modify an Anbernic stock image to hand off to spruce.
# Per https://github.com/spruceUI/RGXX-images
set -euo pipefail

IMG="${1:?usage: mod_image.sh /path/to/image.IMG}"
[ -f "$IMG" ] || { echo "!! no such image: $IMG" >&2; exit 1; }

BACKUP="${IMG%.IMG}.loadapp.sh.orig"
MARKER='#---- third mod need this to mount sdcard ---'
LOOP=""

cleanup() {
    set +e
    mountpoint -q /mnt/appfs && umount /mnt/appfs
    mountpoint -q /mnt/roms  && umount /mnt/roms
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

echo "== attaching loop device =="
LOOP=$(losetup -Pf --show "$IMG")
echo "   $LOOP"
sleep 1

# Confirm the partitions are what we expect before touching anything.
APPFS_LABEL=$(blkid -s LABEL -o value "${LOOP}p6" || true)
ROMS_TYPE=$(blkid -s TYPE -o value "${LOOP}p1" || true)
echo "   p6 label='$APPFS_LABEL'  p1 type='$ROMS_TYPE'"
[ "$APPFS_LABEL" = "appfs" ] || { echo "!! p6 is not appfs, aborting" >&2; exit 1; }
[ "$ROMS_TYPE" = "vfat" ]    || { echo "!! p1 is not vfat, aborting" >&2; exit 1; }

mkdir -p /mnt/appfs /mnt/roms
mount "${LOOP}p6" /mnt/appfs
mount "${LOOP}p1" /mnt/roms

TARGET=/mnt/appfs/ctrl/loadapp.sh
[ -f "$TARGET" ] || { echo "!! $TARGET missing, aborting" >&2; exit 1; }

if grep -q 'anbernic.sh' "$TARGET"; then
    echo "!! loadapp.sh already contains the spruce hook -- already modded? aborting" >&2
    exit 1
fi

COUNT=$(grep -cF "$MARKER" "$TARGET")
[ "$COUNT" = "1" ] || { echo "!! expected 1 marker line, found $COUNT, aborting" >&2; exit 1; }

echo "== backing up original loadapp.sh =="
cp -a "$TARGET" "$BACKUP"
echo "   $BACKUP"

echo "== rewriting loadapp.sh tail =="
NEW=$(mktemp)
awk -v m="$MARKER" '$0 == m { exit } { print }' "$TARGET" > "$NEW"
cat >> "$NEW" <<'BLOCK'
#---- third mod need this to mount sdcard ---
/mnt/vendor/ctrl/mmc_new.sh add

if [ -f "/mnt/mod/ctrl/autostart" ]; then
        /mnt/mod/ctrl/autostart
fi


# Set /mnt/SDCARD to the best available target
if [ -e "/mnt/sdcard" ]; then
    ln -sf /mnt/sdcard /mnt/SDCARD
elif [ -e "/mnt/mmc" ]; then
    ln -sf /mnt/mmc /mnt/SDCARD
fi

# Override if updater exists
if [ -f "/mnt/SDCARD/.tmp_update/anbernic.sh" ]; then
    RunBin="/mnt/SDCARD/.tmp_update/anbernic.sh"
fi


while [ -f $RunBin ]
do
        if [ -f $StopBin ];then
                echo "stop app run ..."
                #systemctl stop NetworkManager.service
                break
        fi

        $RunBin
done
BLOCK

# Write through the existing inode so mode/uid/gid are preserved.
cat "$NEW" > "$TARGET"
rm -f "$NEW"

echo "== syntax check =="
bash -n "$TARGET" && echo "   loadapp.sh parses OK"

echo "== clearing media dirs on roms =="
for d in PDF Music Video; do
    if [ -d "/mnt/roms/$d" ]; then
        rm -rf "/mnt/roms/$d"/*
        echo "   cleared /mnt/roms/$d"
    else
        echo "   (no /mnt/roms/$d, skipped)"
    fi
done

echo "== flushing =="
sync

echo
echo "---- new tail of loadapp.sh ----"
sed -n "/^${MARKER//\//\\/}/,\$p" "$TARGET"
echo "--------------------------------"

echo
echo "== unmounting =="
umount /mnt/appfs
umount /mnt/roms
losetup -d "$LOOP"
LOOP=""
trap - EXIT

echo
echo "DONE. Image modified in place."
echo "Original loadapp.sh saved at: $BACKUP"
losetup -a | grep -q "$IMG" && echo "WARNING: loop still attached" || echo "Loop device detached cleanly."
