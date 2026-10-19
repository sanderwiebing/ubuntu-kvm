#!/usr/bin/env bash
# create-image.sh: build a raw ext4 Ubuntu rootfs image (no partition table)
# usable with both a custom -kernel and the Ubuntu kernel installed inside it.
#
# Usage: sudo ./create-image.sh [-s SIZE] [-o IMAGE] [-k KVER]... [-p PKGS] [-r RELEASE]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RELEASE=noble
MIRROR=http://archive.ubuntu.com/ubuntu
SIZE=8G
OUT=$SCRIPT_DIR/$RELEASE.img
KEY=$SCRIPT_DIR/$RELEASE.id_ed25519
HOSTNAME_VM=ubuntu-vm
KVERS=()
PKGS=systemd-sysv,systemd-resolved,dbus,udev,kmod,openssh-server,iproute2,iputils-ping,sudo,vim,less,curl,ca-certificates,gcc,make,libc6-dev,strace,gdb,psmisc,tmux,bash-completion,initramfs-tools,zstd
EXTRA_PKGS=

display_help() {
    cat >&2 <<EOF
Usage: sudo $0 [option...]

   -s, --size SIZE        Image size (default $SIZE)
   -o, --output IMAGE     Output image (default $OUT)
   -k, --kernel KVER      Also install linux-image/modules KVER (e.g. 6.8.0-71-generic),
                          repeatable. linux-image-virtual is always installed.
   -p, --packages PKGS    Extra packages, comma separated
   -r, --release REL      Ubuntu release (default $RELEASE)
   -m, --mirror URL       Ubuntu mirror (default $MIRROR)
   -h, --help             Display help message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -s | --size)     SIZE=$2; shift 2 ;;
        -o | --output)   OUT=$(realpath -m "$2"); shift 2 ;;
        -k | --kernel)   KVERS+=("$2"); shift 2 ;;
        -p | --packages) EXTRA_PKGS=$2; shift 2 ;;
        -r | --release)  RELEASE=$2; shift 2 ;;
        -m | --mirror)   MIRROR=$2; shift 2 ;;
        -h | --help)     display_help; exit 0 ;;
        *) echo "Error: Unknown option: $1" >&2; display_help; exit 1 ;;
    esac
done

if [ "$(id -u)" != 0 ]; then
    echo "Please run as root: sudo $0 $*" >&2
    exit 1
fi
OWNER=${SUDO_USER:-root}

# Overwriting a base image corrupts the VM overlays (vms/*) built on it
for disk in "$SCRIPT_DIR"/vms/*/disk.qcow2; do
    [ -f "$disk" ] || continue
    if [ "$(realpath -m "$(qemu-img info -U --output=json "$disk" | jq -r '."full-backing-filename"')")" = "$OUT" ]; then
        echo "Error: $OUT is the base of $disk; build to a new name with -o" >&2
        exit 1
    fi
done

DIR=$(mktemp -d "$SCRIPT_DIR/.chroot.XXXXXX")
chmod 0755 "$DIR"

cleanup() {
    for m in dev/pts dev sys proc; do
        mountpoint -q "$DIR/$m" && umount -l "$DIR/$m"
    done
    rm -rf "$DIR"
}
trap cleanup EXIT

# 1. Base system
[ -n "$EXTRA_PKGS" ] && PKGS=$PKGS,$EXTRA_PKGS
debootstrap --variant=minbase --components=main,restricted,universe \
    --include="$PKGS" "$RELEASE" "$DIR" "$MIRROR"

cat > "$DIR/etc/apt/sources.list" <<EOF
deb $MIRROR $RELEASE main restricted universe multiverse
deb $MIRROR $RELEASE-updates main restricted universe multiverse
deb $MIRROR $RELEASE-security main restricted universe multiverse
EOF

# 2. Kernels (needs proc/sys/dev for initramfs generation)
mount -t proc proc "$DIR/proc"
mount -t sysfs sys "$DIR/sys"
mount --bind /dev "$DIR/dev"
mount --bind /dev/pts "$DIR/dev/pts"
cp /etc/resolv.conf "$DIR/etc/resolv.conf" --remove-destination
printf '#!/bin/sh\nexit 101\n' > "$DIR/usr/sbin/policy-rc.d"
chmod +x "$DIR/usr/sbin/policy-rc.d"

KPKGS="linux-image-virtual"
for v in "${KVERS[@]}"; do
    KPKGS="$KPKGS linux-image-$v linux-modules-$v"
done
chroot "$DIR" /bin/bash -c "export DEBIAN_FRONTEND=noninteractive; \
    apt-get update && apt-get -y --no-install-recommends install $KPKGS && apt-get clean"

rm -f "$DIR/usr/sbin/policy-rc.d"
for m in dev/pts dev sys proc; do umount "$DIR/$m"; done

# 3. Configuration
echo "$HOSTNAME_VM" > "$DIR/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$HOSTNAME_VM" > "$DIR/etc/hosts"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$DIR/etc/resolv.conf"

cat > "$DIR/etc/fstab" <<EOF
LABEL=rootfs  /            ext4  defaults,errors=remount-ro  0 1
shared        /mnt/shared  9p    trans=virtio,version=9p2000.L,msize=512000,nofail  0 0
vmboot        /mnt/vmboot  9p    trans=virtio,version=9p2000.L,msize=512000,nofail  0 0
EOF
mkdir -p "$DIR/mnt/shared" "$DIR/mnt/vmboot"

# Mirror /boot kernels+initrds to the host (vms/NAME/boot) so that
# run-vm.sh -n NAME --distro can boot kernels installed inside the VM
cat > "$DIR/usr/local/sbin/export-boot" <<'EOF'
#!/bin/sh
DST=/mnt/vmboot
mountpoint -q $DST || exit 0
for f in /boot/vmlinuz-* /boot/initrd.img-*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    cmp -s "$f" "$DST/${f##*/}" || cp "$f" "$DST/"
done
for f in $DST/vmlinuz-* $DST/initrd.img-*; do
    [ -e "$f" ] && [ ! -e "/boot/${f##*/}" ] && rm -f "$f"
done
exit 0
EOF
chmod +x "$DIR/usr/local/sbin/export-boot"
cat > "$DIR/etc/systemd/system/export-boot.service" <<EOF
[Unit]
Description=Mirror /boot to the host
Wants=mnt-vmboot.mount
After=mnt-vmboot.mount

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/export-boot

[Install]
WantedBy=multi-user.target
EOF
cat > "$DIR/etc/systemd/system/export-boot.path" <<EOF
[Unit]
Description=Watch /boot for kernel changes

[Path]
PathChanged=/boot

[Install]
WantedBy=multi-user.target
EOF
# Final sync at shutdown, catching anything the path unit raced with
cat > "$DIR/etc/systemd/system/export-boot-shutdown.service" <<EOF
[Unit]
Description=Mirror /boot to the host at shutdown
Wants=mnt-vmboot.mount
After=mnt-vmboot.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/local/sbin/export-boot

[Install]
WantedBy=multi-user.target
EOF
# Load 9p early so the fstab mount does not race udev
printf '9p\n9pnet_virtio\n' > "$DIR/etc/modules-load.d/9p.conf"

cat > "$DIR/etc/systemd/network/20-wired.network" <<EOF
[Match]
Name=eth* en*

[Network]
DHCP=yes
EOF

# Passwordless root on the console, key-only root over ssh
passwd -R "$DIR" -d root
mkdir -p "$DIR/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$DIR/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 - \$TERM
EOF
mkdir -p "$DIR/etc/ssh/sshd_config.d"
echo 'PermitRootLogin prohibit-password' > "$DIR/etc/ssh/sshd_config.d/10-vm.conf"

if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -f "$KEY"
    chown "$OWNER": "$KEY" "$KEY.pub"
fi
install -d -m 700 "$DIR/root/.ssh"
install -m 600 "$KEY.pub" "$DIR/root/.ssh/authorized_keys"

chroot "$DIR" systemctl enable systemd-networkd systemd-resolved ssh
chroot "$DIR" systemctl mask systemd-networkd-wait-online
# Return space freed in the guest to the sparse image file (needs discard=unmap)
chroot "$DIR" systemctl enable fstrim.timer
chroot "$DIR" systemctl enable export-boot.service export-boot.path export-boot-shutdown.service

# 4. Disk image
rm -f "$OUT"
truncate -s "$SIZE" "$OUT"
mkfs.ext4 -q -F -L rootfs -d "$DIR" "$OUT"
chown "$OWNER": "$OUT"

echo "Created $OUT"
echo "Kernels in image:"; ls "$DIR/boot" | grep '^vmlinuz-'
