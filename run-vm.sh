#!/usr/bin/env bash
# run-vm.sh: boot the base image or a VM instance (see vm.sh) with QEMU/KVM.
#
#   ./run-vm.sh [options] BZIMAGE      boot a custom kernel (no initrd)
#   ./run-vm.sh [options] --distro     boot the Ubuntu kernel installed in the image
#
# ssh: ./ssh-vm.sh [-n NAME]   shared folder <-> /mnt/shared   quit: Ctrl-a x

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NAME=
IMAGE=
MEM=4G
SMP=2
PORT=
GDB=false
TASKSET=
DISTRO=false
DISTRO_VER=
GLOBAL_SHARED=false
SNAPSHOT=false
FORCE=false
KERNEL=
INITRD=
EXTRA_APPEND=

display_help() {
    cat >&2 <<EOF
Usage: $0 [option...] [BZIMAGE]

   -n, --name NAME     Run VM instance vms/NAME (default: the base image)
   --distro[=KVER]     Boot kernel+initrd installed in the image (default: newest)
   --snapshot          Discard all disk changes when QEMU exits
   --global-shared     Share ./shared instead of vms/NAME/shared
   -i, --image IMAGE   Base image to run without -n (default $SCRIPT_DIR/noble.img)
   --force             Run the base image read-write even if VMs depend on it
   -m, --mem MEM       Memory (default $MEM)
   -c, --smp N         CPUs (default $SMP)
   -p, --port PORT     Host port forwarded to guest ssh (default 7777, or vms/NAME/port)
   -g, --gdb           Start gdb stub on :1234 and boot with nokaslr
   -t, --taskset CPUS  Pin QEMU to host CPUs (e.g. 4 or 4-7)
   -a, --append ARGS   Extra kernel command line arguments
   -h, --help          Display help message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n | --name)     NAME=$2; shift 2 ;;
        --distro)        DISTRO=true; shift ;;
        --distro=*)      DISTRO=true; DISTRO_VER=${1#--distro=}; shift ;;
        --snapshot)      SNAPSHOT=true; shift ;;
        --global-shared) GLOBAL_SHARED=true; shift ;;
        -i | --image)    IMAGE=$(realpath "$2"); shift 2 ;;
        --force)         FORCE=true; shift ;;
        -m | --mem)      MEM=$2; shift 2 ;;
        -c | --smp)      SMP=$2; shift 2 ;;
        -p | --port)     PORT=$2; shift 2 ;;
        -g | --gdb)      GDB=true; shift ;;
        -t | --taskset)  TASKSET=$2; shift 2 ;;
        -a | --append)   EXTRA_APPEND=$2; shift 2 ;;
        -h | --help)     display_help; exit 0 ;;
        -*) echo "Error: Unknown option: $1" >&2; display_help; exit 1 ;;
        *)  KERNEL=$(realpath "$1"); shift ;;
    esac
done

# Overlays in vms/ whose backing file is $1
image_users() {
    local disk
    for disk in "$SCRIPT_DIR"/vms/*/disk.qcow2; do
        [ -f "$disk" ] || continue
        [ "$(realpath -m "$(qemu-img info -U --output=json "$disk" | jq -r '."full-backing-filename"')")" = "$1" ] &&
            basename "$(dirname "$disk")"
    done
    return 0
}

if [ -n "$NAME" ]; then
    [ -z "$IMAGE" ] || { echo "Error: -i and -n are exclusive" >&2; exit 1; }
    VM_DIR=$SCRIPT_DIR/vms/$NAME
    [ -f "$VM_DIR/disk.qcow2" ] || { echo "VM $NAME not found, create it with: ./vm.sh new $NAME" >&2; exit 1; }
    IMAGE=$VM_DIR/disk.qcow2
    SHARED=$VM_DIR/shared
    BOOT_DIR=$VM_DIR/boot
    PORT=${PORT:-$(cat "$VM_DIR/port")}
else
    VM_DIR=$SCRIPT_DIR
    IMAGE=${IMAGE:-$SCRIPT_DIR/noble.img}
    [ -f "$IMAGE" ] || { echo "Image $IMAGE not found, run create-image.sh first" >&2; exit 1; }
    SHARED=$SCRIPT_DIR/shared
    BOOT_DIR=
    PORT=${PORT:-7777}
    USERS=$(image_users "$IMAGE")
    if [ -n "$USERS" ] && ! $SNAPSHOT && ! $FORCE; then
        echo "Error: $IMAGE is the base of VM(s): $(echo $USERS)" >&2
        echo "Writing to it would corrupt them. Use --snapshot, -n NAME, or --force." >&2
        exit 1
    fi
fi
$GLOBAL_SHARED && SHARED=$SCRIPT_DIR/shared
FORMAT=$(qemu-img info -U "$IMAGE" | awk '/^file format:/ { print $3 }')

if $DISTRO; then
    if [ -n "$BOOT_DIR" ]; then
        # Kept in sync by the guest (export-boot) and seeded by vm.sh new
        [ -n "$DISTRO_VER" ] ||
            DISTRO_VER=$(ls "$BOOT_DIR" | sed -n 's/^vmlinuz-//p' | sort -V | tail -1)
        KERNEL=$BOOT_DIR/vmlinuz-$DISTRO_VER
        INITRD=$BOOT_DIR/initrd.img-$DISTRO_VER
    else
        # Extract kernel and initrd from the raw image without mounting it
        [ "$FORMAT" = raw ] || { echo "Error: --distro without -n needs a raw image" >&2; exit 1; }
        if [ -z "$DISTRO_VER" ]; then
            DISTRO_VER=$(debugfs -R "ls -p /boot" "$IMAGE" 2>/dev/null |
                awk -F/ '$3 ~ /^100/ && $6 ~ /^vmlinuz-/ { sub(/^vmlinuz-/, "", $6); print $6 }' |
                sort -V | tail -1)
        fi
        mkdir -p "$SCRIPT_DIR/.boot"
        KERNEL=$SCRIPT_DIR/.boot/vmlinuz-$DISTRO_VER
        INITRD=$SCRIPT_DIR/.boot/initrd.img-$DISTRO_VER
        debugfs -R "dump /boot/vmlinuz-$DISTRO_VER $KERNEL" "$IMAGE" 2>/dev/null
        debugfs -R "dump /boot/initrd.img-$DISTRO_VER $INITRD" "$IMAGE" 2>/dev/null
    fi
    [ -n "$DISTRO_VER" ] && [ -s "$KERNEL" ] || { echo "Kernel ${DISTRO_VER:-?} not found in image" >&2; exit 1; }
    echo "Booting distro kernel $DISTRO_VER"
fi

[ -n "$KERNEL" ] || { echo "Error: pass a BZIMAGE or --distro" >&2; display_help; exit 1; }

APPEND="console=ttyS0 earlyprintk=serial root=/dev/vda rw net.ifnames=0 mitigations=off"
QEMU_ARGS=()
if $GDB; then
    APPEND="$APPEND nokaslr"
    QEMU_ARGS+=(-s)
fi
[ -n "$EXTRA_APPEND" ] && APPEND="$APPEND $EXTRA_APPEND"
[ -n "$INITRD" ] && QEMU_ARGS+=(-initrd "$INITRD")
$SNAPSHOT && QEMU_ARGS+=(-snapshot)
if [ -n "$BOOT_DIR" ]; then
    # Guest mirrors its /boot here; read-only in snapshot mode so it stays
    # consistent with the (unchanged) disk
    mkdir -p "$BOOT_DIR"
    RO=$($SNAPSHOT && echo ,readonly=on || true)
    QEMU_ARGS+=(-virtfs local,path="$BOOT_DIR",mount_tag=vmboot,security_model=mapped-xattr,id=vmboot$RO)
fi

mkdir -p "$SHARED"
cd "$VM_DIR"

PREFIX=()
[ -n "$TASKSET" ] && PREFIX=(taskset -c "$TASKSET")

exec "${PREFIX[@]}" qemu-system-x86_64 \
    -name "${NAME:-base}" \
    -enable-kvm \
    -cpu host \
    -m "$MEM" \
    -smp "$SMP" \
    -kernel "$KERNEL" \
    -append "$APPEND" \
    -drive file="$IMAGE",format="$FORMAT",if=virtio,discard=unmap \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$PORT"-:22 \
    -device virtio-net-pci,netdev=net0 \
    -virtfs local,path="$SHARED",mount_tag=shared,security_model=mapped-xattr,id=shared \
    -nographic \
    -pidfile vm.pid \
    -qmp unix:qmp.sock,server=on,wait=off \
    "${QEMU_ARGS[@]}"
