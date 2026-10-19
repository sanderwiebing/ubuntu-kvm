#!/usr/bin/env bash
# download-kernel.sh: fetch an Ubuntu kernel (vmlinuz, config, debug vmlinux and
# optionally source) from Launchpad. No sudo or host apt configuration needed;
# works for any series (noble, jammy, ...) and derivative (generic, aws, ...).
#
# Usage: ./download-kernel.sh [options] VERSION [FLAVOUR]
#   ./download-kernel.sh 6.8.0-71                  # 6.8.0-71-generic
#   ./download-kernel.sh 6.8.0-71-generic --src
#   ./download-kernel.sh 6.8.0-1030 aws --no-dbg

set -euo pipefail

LP_API=https://api.launchpad.net/1.0/ubuntu/+archive/primary
LP_FILES=https://launchpad.net/ubuntu/+archive/primary/+files
LP_GIT=https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source

ARCH=amd64
DBG=true
SRC=
OUT=
VERSION=
FLAVOUR=

display_help() {
    cat >&2 <<EOF
Usage: $0 [option...] VERSION [FLAVOUR]

   VERSION              ABI version (6.8.0-71), with upload number (6.8.0-71.71)
                        or full release name (6.8.0-71-generic)
   FLAVOUR              Kernel flavour (default generic)
   --src[=METHOD]       Also fetch the source into OUT/src. METHOD is
                          git      shallow clone of the matching Ubuntu tag (default)
                          tarball  orig tarball + Ubuntu diff from the source package
   --no-dbg             Skip the debug symbols package (large)
   -a, --arch ARCH      Architecture (default $ARCH)
   -o, --output DIR     Output directory (default ./<VERSION>-<FLAVOUR>)
   -h, --help           Display help message

Output: vmlinuz, config, vmlinux-dbg (unless --no-dbg), vmlinux, src/, debs/
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --src)          SRC=git; shift ;;
        --src=*)        SRC=${1#--src=}; shift ;;
        --no-dbg)       DBG=false; shift ;;
        -a | --arch)    ARCH=$2; shift 2 ;;
        -o | --output)  OUT=$2; shift 2 ;;
        -h | --help)    display_help; exit 0 ;;
        -*) echo "Error: Unknown option: $1" >&2; display_help; exit 1 ;;
        *)
            if [ -z "$VERSION" ]; then VERSION=$1
            elif [ -z "$FLAVOUR" ]; then FLAVOUR=$1
            else echo "Error: too many arguments" >&2; exit 1
            fi
            shift ;;
    esac
done

[ -n "$VERSION" ] || { display_help; exit 1; }
case "$SRC" in ""|git|tarball) ;; *) echo "Error: unknown --src method: $SRC" >&2; exit 1 ;; esac
for t in curl jq dpkg-deb; do
    command -v $t >/dev/null || { echo "Please install $t" >&2; exit 1; }
done

# Split VERSION into ABI (6.8.0-71), optional upload number (.71) and flavour
PIN=
if [[ $VERSION =~ ^([0-9.]+-[0-9]+)-([a-z].*)$ ]]; then
    VERSION=${BASH_REMATCH[1]}
    FLAVOUR=${FLAVOUR:-${BASH_REMATCH[2]}}
elif [[ $VERSION =~ ^([0-9.]+-[0-9]+)\.(.+)$ ]]; then
    PIN=$VERSION
    VERSION=${BASH_REMATCH[1]}
fi
FLAVOUR=${FLAVOUR:-generic}
KREL=$VERSION-$FLAVOUR
OUT=${OUT:-$KREL}

# 1. Look up package version, source package and series on Launchpad
echo "[+] Looking up linux-image-unsigned-$KREL ($ARCH)"
INFO=$(curl -fsS "$LP_API?ws.op=getPublishedBinaries&binary_name=linux-image-unsigned-$KREL&exact_match=true" |
    jq -r --arg arch "$ARCH" --arg pin "$PIN" '
        [.entries[] | select(.distro_arch_series_link | endswith("/" + $arch))
                    | select($pin == "" or .binary_package_version == $pin)][0]
        | select(. != null)
        | "\(.binary_package_version) \(.source_package_name) \(.distro_arch_series_link | split("/")[-2])"')
[ -n "$INFO" ] || { echo "linux-image-unsigned-$KREL ${PIN:+($PIN) }not found for $ARCH" >&2; exit 1; }
read -r PKGVER SRCPKG SERIES <<< "$INFO"
echo "    version $PKGVER, source $SRCPKG, series $SERIES"

mkdir -p "$OUT/debs"
cd "$OUT"

fetch() {  # fetch FILENAME -> debs/FILENAME (cached)
    [ -f "debs/$1" ] && return
    echo "[+] Downloading $1"
    curl -fL --progress-bar --retry 3 -o "debs/$1.part" "$LP_FILES/$1"
    mv "debs/$1.part" "debs/$1"
}

# 2. Kernel image
IMG=linux-image-unsigned-${KREL}_${PKGVER}_${ARCH}.deb
fetch "$IMG"
dpkg-deb --fsys-tarfile "debs/$IMG" | tar -xO --wildcards './boot/vmlinuz-*' > vmlinuz

# 3. Config
HDR=linux-headers-${KREL}_${PKGVER}_${ARCH}.deb
fetch "$HDR"
dpkg-deb --fsys-tarfile "debs/$HDR" | tar -xO --wildcards './usr/src/*/.config' > config

# 4. Debug symbols
if $DBG; then
    DDEB=linux-image-unsigned-${KREL}-dbgsym_${PKGVER}_${ARCH}.ddeb
    fetch "$DDEB"
    dpkg-deb --fsys-tarfile "debs/$DDEB" | tar -xO --wildcards './usr/lib/debug/boot/vmlinux-*' > vmlinux-dbg
    ln -sf vmlinux-dbg vmlinux
elif EXTRACT=$(ls /usr/src/linux-headers-*/scripts/extract-vmlinux 2>/dev/null | head -1) &&
     [ -n "$EXTRACT" ] && command -v readelf >/dev/null; then
    "$EXTRACT" vmlinuz > vmlinux
else
    echo "[!] Skipping vmlinux: needs extract-vmlinux and readelf (binutils)" >&2
fi

# 5. Source
fetch_src_tarball() {
    echo "[+] Fetching source package $SRCPKG $PKGVER"
    local self files
    self=$(curl -fsS "$LP_API?ws.op=getPublishedSources&source_name=$SRCPKG&version=$PKGVER&exact_match=true" |
        jq -r '.entries[0].self_link')
    files=$(curl -fsS "$self?ws.op=sourceFileUrls" | jq -r '.[]')
    mkdir -p debs/src
    for url in $files; do
        f=$(basename "$url")
        [ -f "debs/src/$f" ] && continue
        echo "[+] Downloading $f"
        curl -fL --progress-bar --retry 3 -o "debs/src/$f.part" "$url"
        mv "debs/src/$f.part" "debs/src/$f"
    done
    rm -rf src.part && mkdir src.part
    tar -xf debs/src/*.orig.tar.* -C src.part --strip-components=1
    if ls debs/src/*.diff.gz >/dev/null 2>&1; then
        zcat debs/src/*.diff.gz | patch -s -p1 -d src.part
    else
        tar -xf debs/src/*.debian.tar.* -C src.part
    fi
    mv src.part src
}

fetch_src_git() {
    # Tags look like Ubuntu-6.8.0-71.71 or Ubuntu-aws-6.8.0-1030.32 ('~' -> '_')
    local suffix=${SRCPKG#linux}
    local tag="Ubuntu${suffix}-${PKGVER//\~/_}"
    local repo="$LP_GIT/$SRCPKG/+git/$SERIES"
    echo "[+] Cloning $repo at $tag"
    GIT_TERMINAL_PROMPT=0 git -c advice.detachedHead=false clone --depth 1 --branch "$tag" "$repo" src
}

if [ -n "$SRC" ]; then
    if [ -d src ]; then
        echo "[+] src/ already exists, skipping source"
    elif [ "$SRC" = git ]; then
        fetch_src_git || { echo "[!] git clone failed, falling back to tarball" >&2; rm -rf src; fetch_src_tarball; }
    else
        fetch_src_tarball
    fi
fi

echo "[+] Done: $(pwd)"
ls -l
