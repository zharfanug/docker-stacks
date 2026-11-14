#!/usr/bin/env bash
# Puts /stacks on its own blank disk: LVM volume group "vg_data", logical
# volume "lv_data" (the whole disk), ext4, mounted by UUID.
#
#   sudo scripts/data-disk.sh /dev/sdX
#
# Refuses a disk that has partitions, a file system or any other signature.
# Safe to run again once /stacks is mounted from the volume.
set -euo pipefail

MOUNT=/stacks
VG=vg_data
LV=lv_data

log() { printf '==> %s\n' "$*"; }
die() { printf 'data-disk.sh: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 /dev/sdX"
[ $# -eq 1 ] || die "usage: sudo $0 /dev/sdX"
dev=$1
lvpath=/dev/$VG/$LV

if mountpoint -q "$MOUNT"; then
  src=$(findmnt -no SOURCE "$MOUNT")
  [ "$(readlink -f "$src")" = "$(readlink -f "$lvpath" 2>/dev/null || echo none)" ] ||
    die "$MOUNT is already mounted from $src"
  log "$MOUNT is already mounted from $lvpath; nothing to do"
  exit 0
fi

[ -b "$dev" ] || die "$dev is not a block device"
[ "$(lsblk -dno TYPE "$dev")" = disk ] || die "$dev is not a whole disk"
[ "$(lsblk -no NAME "$dev" | wc -l)" -eq 1 ] || die "$dev has partitions or holders"
[ -z "$(wipefs -n "$dev" 2>/dev/null | tail -n +2)" ] || die "$dev is not blank (wipefs found signatures)"
[ -z "$(blkid -p "$dev" 2>/dev/null)" ] || die "$dev is not blank (blkid found a signature)"
! vgs "$VG" >/dev/null 2>&1 || die "volume group $VG already exists"
grep -qE "^[^#]*[[:space:]]${MOUNT}[[:space:]]" /etc/fstab && die "/etc/fstab already has an entry for $MOUNT"

if ! command -v pvcreate >/dev/null; then
  log "installing lvm2"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends lvm2 >/dev/null
fi

log "LVM on $dev: volume group $VG, logical volume $LV"
pvcreate -q "$dev"
vgcreate -q "$VG" "$dev"
lvcreate -q -y -n "$LV" -l 100%FREE "$VG"

log "ext4 on $lvpath (label stacks, 1 % reserved for root)"
mkfs.ext4 -q -L stacks -m 1 "$lvpath"
uuid=$(blkid -s UUID -o value "$lvpath")

# Immutable while nothing is mounted on it: if the disk is missing at boot,
# nothing can write into the empty directory on the system disk.
install -d -m 0755 "$MOUNT"
[ -z "$(ls -A "$MOUNT")" ] || die "$MOUNT is not empty"
chattr +i "$MOUNT"

log "/etc/fstab: UUID=$uuid $MOUNT"
printf '# docker-stacks data disk (LVM %s/%s)\nUUID=%s %s ext4 defaults,noatime,nodev,nosuid,nofail,x-systemd.device-timeout=30s 0 2\n' \
  "$VG" "$LV" "$uuid" "$MOUNT" >> /etc/fstab
systemctl daemon-reload
mount "$MOUNT"
chmod 0755 "$MOUNT"

# Containers start only with the disk mounted, never on the empty directory.
log "docker.service requires $MOUNT"
install -d -m 0755 /etc/systemd/system/docker.service.d
printf '[Unit]\n# docker-stacks: container data lives on the /stacks disk.\nRequiresMountsFor=%s\n' "$MOUNT" \
  > /etc/systemd/system/docker.service.d/10-stacks.conf
systemctl daemon-reload

df -h "$MOUNT"
cat <<EOF

$MOUNT is on $lvpath ($dev). To grow it later: add space to the disk (or a
new disk to volume group $VG), then
  sudo pvresize $dev && sudo lvextend -r -l +100%FREE $lvpath
EOF
