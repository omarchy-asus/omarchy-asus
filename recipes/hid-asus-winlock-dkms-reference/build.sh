#!/bin/sh
# DKMS MAKE step. Builds hid-asus with winlock.patch only from a source that is
# proven identical to the target kernel's own stock hid-asus:
#   for each variants/*/ (an unpatched hid-asus.c + hid-ids.h), compile it as-is
#   and compare with the stock module: same machine code (.text) and the same
#   device-ID table (modinfo aliases). The first match gets winlock.patch.
# No match -> exit 1: DKMS installs nothing and the stock driver keeps running.
# That covers point releases automatically when hid-asus did not change, and
# refuses (instead of silently downgrading the driver) when it did.
set -u
kver=$1 kdir=$2
here=$(pwd)
log() { echo "hid-asus-winlock: $*" >&2; }

stock=$(ls /usr/lib/modules/"$kver"/kernel/drivers/hid/hid-asus.ko* 2>/dev/null | head -1)
[ -n "$stock" ] || { log "no stock hid-asus in /usr/lib/modules/$kver; refusing"; exit 1; }
case "$stock" in
    *.zst) zstd -qdcf "$stock" > stock.ko ;;
    *.xz)  xz -dc "$stock" > stock.ko ;;
    *.gz)  gzip -dc "$stock" > stock.ko ;;
    *)     cp "$stock" stock.ko ;;
esac
fp() {
    { objcopy -O binary --only-section=.text "$1" /dev/stdout; modinfo -F alias "$1" | sort; } | sha256sum
}
want=$(fp stock.ko)

match=
for v in variants/*/; do
    rm -rf try && mkdir try && cp "$v"hid-asus.c "$v"hid-ids.h Makefile try/
    make -C "$kdir" M="$here/try" modules >try.log 2>&1 || continue
    [ "$(fp try/hid-asus.ko)" = "$want" ] && { match=$v; break; }
done
rm -rf try try.log stock.ko
[ -n "$match" ] || { log "no variant matches the stock hid-asus of $kver; keeping stock (add a variant, see README.md)"; exit 1; }
log "variant ${match%/} matches the stock driver of $kver"

cp "$match"hid-asus.c "$match"hid-ids.h . &&
patch -p1 --no-backup-if-mismatch < winlock.patch &&
make -C "$kdir" M="$here" modules
