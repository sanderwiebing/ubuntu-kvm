#!/usr/bin/env bash
# vm.sh: manage VM instances in vms/NAME. Each VM is a qcow2 overlay on top of
# the (read-only) base image, with its own ssh port, shared folder and /boot copy.
#
#   ./vm.sh new NAME [-b BASE]   fresh VM from the base image
#   ./vm.sh fork SRC DST         copy of a (stopped) VM's current state
#   ./vm.sh rm NAME [-f]         delete a VM
#   ./vm.sh ls                   list VMs

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
VMS=$SCRIPT_DIR/vms
BASE=$SCRIPT_DIR/noble.img
FIRST_PORT=7778

display_help() {
    sed -n '2,9s/^# \{0,1\}//p' "$0" >&2
}

die() { echo "Error: $*" >&2; exit 1; }

is_running() {
    local pid
    pid=$(cat "$VMS/$1/vm.pid" 2>/dev/null) && kill -0 "$pid" 2>/dev/null
}

next_port() {
    local max=$((FIRST_PORT - 1)) p f
    for f in "$VMS"/*/port; do
        [ -f "$f" ] || continue
        p=$(cat "$f")
        [ "$p" -gt "$max" ] && max=$p
    done
    echo $((max + 1))
}

check_name() {
    [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid VM name: $1"
}

# Copy kernels and initrds from a raw image's /boot into DIR
seed_boot() {
    local img=$1 dir=$2 f
    mkdir -p "$dir"
    for f in $(debugfs -R "ls -p /boot" "$img" 2>/dev/null |
               awk -F/ '$3 ~ /^100/ && $6 ~ /^(vmlinuz|initrd\.img)-/ { print $6 }'); do
        debugfs -R "dump /boot/$f $dir/$f" "$img" 2>/dev/null
    done
}

cmd_new() {
    local name=${1:-}
    [ -n "$name" ] || die "usage: vm.sh new NAME [-b BASE]"
    shift
    [ "${1:-}" = -b ] && { BASE=$(realpath "$2"); shift 2; }
    check_name "$name"
    [ -f "$BASE" ] || die "base image $BASE not found, run create-image.sh first"
    local dir=$VMS/$name
    [ -e "$dir" ] && die "VM $name already exists"

    mkdir -p "$dir/shared"
    # Relative backing path, so the whole directory can be moved
    qemu-img create -q -f qcow2 -F raw -b "$(realpath --relative-to="$dir" "$BASE")" "$dir/disk.qcow2"
    seed_boot "$BASE" "$dir/boot"
    local port; port=$(next_port)
    echo "$port" > "$dir/port"
    echo "Created VM $name (ssh port $(cat "$dir/port"))"
}

cmd_fork() {
    local src=${1:-} dst=${2:-}
    [ -n "$src" ] && [ -n "$dst" ] || die "usage: vm.sh fork SRC DST"
    check_name "$dst"
    [ -f "$VMS/$src/disk.qcow2" ] || die "VM $src not found"
    [ -e "$VMS/$dst" ] && die "VM $dst already exists"
    is_running "$src" && die "VM $src is running, shut it down first"

    mkdir -p "$VMS/$dst/shared"
    cp --sparse=always "$VMS/$src/disk.qcow2" "$VMS/$dst/disk.qcow2"
    cp -a "$VMS/$src/boot" "$VMS/$dst/boot"
    local port; port=$(next_port)
    echo "$port" > "$VMS/$dst/port"
    echo "Forked $src -> $dst (ssh port $(cat "$VMS/$dst/port"), empty shared folder)"
}

cmd_rm() {
    local name=${1:-} force=${2:-}
    [ -n "$name" ] || die "usage: vm.sh rm NAME [-f]"
    [ -d "$VMS/$name" ] || die "VM $name not found"
    is_running "$name" && die "VM $name is running"
    if [ "$force" != -f ]; then
        read -r -p "Delete $VMS/$name (disk and shared folder)? [y/N] " ans
        [ "$ans" = y ] || exit 1
    fi
    rm -rf "${VMS:?}/$name"
}

cmd_ls() {
    local d name state
    printf '%-16s %-6s %-8s %-8s %s\n' NAME PORT DISK STATE BASE
    for d in "$VMS"/*/; do
        [ -f "$d/disk.qcow2" ] || continue
        name=$(basename "$d")
        state=$(is_running "$name" && echo running || echo stopped)
        printf '%-16s %-6s %-8s %-8s %s\n' "$name" "$(cat "$d/port")" \
            "$(du -h "$d/disk.qcow2" | cut -f1)" "$state" \
            "$(qemu-img info -U --output=json "$d/disk.qcow2" | jq -r '."backing-filename"')"
    done
}

case "${1:-}" in
    new)  shift; cmd_new "$@" ;;
    fork) shift; cmd_fork "$@" ;;
    rm)   shift; cmd_rm "$@" ;;
    ls)   cmd_ls ;;
    *)    display_help; exit 1 ;;
esac
