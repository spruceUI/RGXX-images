# Modifying Anbernic Stock Images to Launch spruce

A start-to-finish guide for patching an Anbernic RGXX stock `.IMG` so it hands
off to spruce, then packaging it for a GitHub release.

The core patch is described in this repo's README. This guide adds the steps
around it — layout verification, free-space zeroing, packaging and validation —
which is where most of the real work turns out to be.

The two scripts referenced below are included in full in the
[Appendix](#appendix-scripts).

---

## What this mod actually does

It does **not** install spruce. Spruce boots from the user's external SD2.

All this does is patch the stock launcher so that, if it finds spruce on the SD
card, it runs spruce instead of the Anbernic menu. Exactly one file changes:
`appfs/ctrl/loadapp.sh`.

Everything from the `#---- third mod need this to mount sdcard ---` comment to
end-of-file is replaced with a block that:

- mounts the SD card (`mmc_new.sh add`)
- runs `/mnt/mod/ctrl/autostart` if present
- symlinks `/mnt/SDCARD` → `/mnt/sdcard`, falling back to `/mnt/mmc`
- if `/mnt/SDCARD/.tmp_update/anbernic.sh` exists, points `RunBin` at it
- loops `$RunBin` until `$StopBin` appears

**The `sdcard`-before-`mmc` order is load-bearing.** Spruce lives on external
SD2 (`/mnt/sdcard`). If `mmc` were checked first, a device with both cards
populated would resolve `/mnt/SDCARD` to internal SD1 and never find
`anbernic.sh`.

We also empty `PDF/`, `Music/` and `Video/` on the roms partition.

Note the replacement block **drops the `$DEBUG` wait loop** present in stock.
It only triggers when `/mnt/data/xudebug.ini` exists, so removing it is
harmless in normal use. The now-unused `DEBUG=` variable stays declared near
the top of the file; leave it alone.

---

## Prerequisites

- `sudo` (for loop mounting)
- `p7zip` (`7z`)
- `e2fsprogs` (`debugfs`) and `mtools` — optional, for no-sudo inspection
- Free disk space: image size + roughly 1.5× the expected archive

Save the two Appendix scripts somewhere and make them executable:

```bash
mkdir -p scripts
# paste mod_image.sh and zerofill.sh into scripts/
chmod +x scripts/*.sh
```

---

## Step 1 — Verify the partition layout

**Never assume the layout.** It is confirmed as appfs=**p6**, roms=**p1** on
RG35XXSP and RG35XXH, but other models may differ.

```bash
IMG=RG35XXH-V1.2.4-EN16GB-260522.IMG
fdisk -l "$IMG"
```

Identify each filesystem without mounting anything. Byte offset = start sector
× 512:

```bash
# e.g. partition starting at sector 19177472 → 19177472 * 512 = 9818865664
dd if="$IMG" bs=512 skip=19177472 count=16 2>/dev/null | file -b -
```

You are looking for two partitions:

- the ext4 one labelled **`appfs`** → contains `ctrl/loadapp.sh`
- the **vfat** one → contains `PDF` / `Music` / `Video`

You can also read files straight out of the image with no sudo and no mounting,
which is handy for inspection and verification:

```bash
# ext4, offset = start_sector * 512
debugfs -R "cat /ctrl/loadapp.sh" "$IMG?offset=9818865664"

# vfat
mdir -i "$IMG@@37748736" ::/
```

---

## Step 2 — Patch loadapp.sh and clear the media dirs

```bash
sudo bash scripts/mod_image.sh "$IMG"
```

The script:

1. attaches with `losetup -Pf --show` — never assumes `/dev/loop0`
2. **verifies** p6 is labelled `appfs` and p1 is `vfat`, aborting otherwise
3. refuses to run if the hook is already present, so it can't double-patch
4. backs the original up to `<image>.loadapp.sh.orig`, *outside* the image
5. truncates at the marker comment and appends the replacement block
6. writes through the existing inode so mode `0777` and uid:gid `1000` survive
7. runs `bash -n` on the result to catch a broken edit early
8. clears `PDF` / `Music` / `Video`, syncs, unmounts, detaches

An `EXIT` trap unmounts and detaches even on failure, so an abort won't leave a
loop device pinning your image.

> **If it aborts on the layout check, don't override it.** That guard is what
> stops you writing to the wrong partition on an unfamiliar model. Go back to
> step 1 and identify the real appfs/vfat partitions.

---

## Step 3 — Zero the free space ⚠️ **DO NOT SKIP**

**This step is not in the README, and it is the single biggest factor in
release size.**

Free space in a stock image is full of old deleted data — effectively random
bytes that don't compress. Overwriting it with zeros changes nothing
functionally, but lets 7z collapse the empty space to almost nothing.

```bash
sudo bash scripts/zerofill.sh "$IMG"
```

Measured on RG35XXH-V1.2.4 (14.4 GB image):

| | without zerofill | with zerofill |
|---|---|---|
| archive size | ~5.2 GB (projected) | ~2.8 GB |
| compression speed | ~3 MB/s | 8–22 MB/s |
| image zero content | ~0% | 65% |

Existing releases in this repo are all 2.1–2.3 GB. **If your archive is heading
for ~5 GB, you skipped this step.**

The script mounts each large partition, writes zeros until full, deletes the
file, and unmounts. Two things that look alarming but are expected:

- each partition briefly shows **100% full**
- `dd` finishes with **"no space left on device"** — that's the stop condition,
  not an error

It only touches ext2/3/4 and vfat partitions and skips the small boot/raw ones,
in particular the Android bootimg partition.

`zerofree` is the conventional tool, but it requires a read-only mount, often
isn't installed, and doesn't handle vfat. The `dd` method needs no extra
package and works on both.

### Verify it worked

```bash
TOTAL=$(stat -c %s "$IMG"); tot=0; nz=0
for i in $(seq 0 19); do
  off=$(( i * (TOTAL/20) ))
  b=$(dd if="$IMG" bs=1M count=8 iflag=skip_bytes skip=$off 2>/dev/null | tr -d '\0' | wc -c)
  tot=$((tot+8388608)); nz=$((nz+b))
done
echo "zeros: $(( (tot-nz)*100/tot ))%"
```

Expect **60%+ zeros**.

Note `count=8` with `bs=1M` and **only** `skip_bytes` in `iflag`. Adding
`count_bytes` makes `count=8` mean 8 *bytes* rather than 8 MB, and the check
silently reports ~100% zeros regardless of reality.

---

## Step 4 — Compress

GitHub rejects any single release asset over **2 GiB**, so the archive has to
be split into volumes.

```bash
7z a -t7z -m0=lzma2 -mx=9 -v1900m "${IMG%.IMG}.7z" "$IMG"
```

- `-v1900m` → 1900 MiB volumes; under the cap, and 2 parts for anything up to
  3.8 GB. Earlier releases used `-v1300m`; either works.
- omit `-mmt` to use all cores; set `-mmt=2` (or similar) only to *limit*
  threads on a weak CPU
- `-mx=9` on a fast machine, `-mx=5` if you're CPU-bound

Output is `NAME.7z.001`, `NAME.7z.002`, … These are plain byte-splits of a
single archive stream, so `split -n` after the fact produces identical results
if you ever need to re-slice without recompressing.

7z writes `.001.tmp` while working and renames on completion. A lingering
`.tmp` means it's either still running or it died.

### Monitoring gotchas

- `/usr/bin/7z` is a **wrapper** that spawns the real worker as a separate pid.
  Watch `/usr/lib/7zip/7z`, not the wrapper, or you'll think it finished
  instantly.
- Don't `pgrep -f "<pattern>"` from a watcher script whose own command line
  contains that pattern — it matches itself and the loop never exits.
- Projecting final size in shell arithmetic overflows int64
  (`archive_bytes * image_bytes` exceeds 9.2e18) and prints negative numbers.
  Use awk floating point.

---

## Step 5 — Verify before uploading

```bash
7z t "${IMG%.IMG}.7z.001"      # integrity test; reads all parts
ls -la "${IMG%.IMG}".7z.*      # confirm every part is under 2 GiB
```

Confirm the patch is actually in the image:

```bash
debugfs -R "cat /ctrl/loadapp.sh" "$IMG?offset=<appfs_offset>" | grep anbernic.sh
```

---

## Step 6 — Upload

Attach **every part** to the release. A missing part makes the whole set
unextractable.

```bash
gh release upload images "${IMG%.IMG}".7z.* --repo spruceUI/RGXX-images
```

Users download all parts into one folder and extract `.001`; 7-Zip pulls in the
rest automatically.

---

## Step 7 — Clean up

```bash
rm -f "$IMG" "${IMG%.IMG}".7z.* "${IMG%.IMG}.loadapp.sh.orig"
```

Don't upload the `.loadapp.sh.orig` — it's a local revert backup, not release
material.

---

## Reverting a bad patch

No re-download needed as long as you still have the `.orig` backup:

```bash
LOOP=$(sudo losetup -Pf --show "$IMG")
sudo mount "${LOOP}p6" /mnt/appfs
sudo cp "${IMG%.IMG}.loadapp.sh.orig" /mnt/appfs/ctrl/loadapp.sh
sudo chmod 0777 /mnt/appfs/ctrl/loadapp.sh
sudo chown 1000:1000 /mnt/appfs/ctrl/loadapp.sh
sync && sudo umount /mnt/appfs && sudo losetup -d "$LOOP"
```

---

## Quick reference

```bash
IMG="RG35XXH-V1.2.4-EN16GB-260522.IMG"

fdisk -l "$IMG"                          # 1. confirm layout
sudo bash scripts/mod_image.sh "$IMG"    # 2. patch + clear media dirs
sudo bash scripts/zerofill.sh "$IMG"     # 3. zero free space (DON'T SKIP)
7z a -t7z -m0=lzma2 -mx=9 -v1900m "${IMG%.IMG}.7z" "$IMG"   # 4. compress
7z t "${IMG%.IMG}.7z.001"                # 5. verify
gh release upload images "${IMG%.IMG}".7z.* --repo spruceUI/RGXX-images
rm -f "$IMG" "${IMG%.IMG}".7z.* "${IMG%.IMG}.loadapp.sh.orig"
```

---

## Known-good reference points

| device | archive | volumes | appfs / roms |
|---|---|---|---|
| RG28XX-V1.1.2-EN16GB | 2.1 GB | 2 × `-v1300m` | — |
| RG34XXSP-V1.0.5-EN16GB | 2.3 GB | 2 × `-v1300m` | — |
| RG35XXSP-V1.1.4-EN16GB | 2.2 GB | 2 × `-v1300m` | p6 / p1 |
| RG35XXH-V1.2.4-EN16GB | _pending_ | `-v1900m` | p6 / p1 |

Always verify the partition layout per model rather than trusting the table.

---

# Appendix: Scripts

## `scripts/mod_image.sh`

Patches `loadapp.sh` and clears the media directories.

```bash
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
```

## `scripts/zerofill.sh`

Zeroes free space so the image compresses properly. **Run this before 7z.**

```bash
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
```

### Adapting `zerofill.sh` to other models

The partition list `for part in 1 5 6 7` is specific to the RG35XXH/RG35XXSP
layout. On a different model, run `fdisk -l` first and list that model's large
data partitions instead. The `blkid` type check means a wrong guess is skipped
rather than acted on, but don't rely on that alone — and never add the Android
bootimg partition to the list.
