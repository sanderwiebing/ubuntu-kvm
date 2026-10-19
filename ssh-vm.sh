#!/bin/sh
# ssh-vm.sh [-n NAME] [ssh args...]: ssh into the base VM or VM instance NAME
# as root, e.g. ./ssh-vm.sh -n a uname -a
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PORT=${PORT:-7777}

if [ "$1" = -n ]; then
    PORT=$(cat "$SCRIPT_DIR/vms/$2/port") || exit 1
    shift 2
fi

exec ssh -i "$SCRIPT_DIR/noble.id_ed25519" -p "$PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    root@localhost "$@"
