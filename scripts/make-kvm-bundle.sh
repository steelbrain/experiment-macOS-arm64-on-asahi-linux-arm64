#!/usr/bin/env bash
# Makes an Ambrosia configuration bundle for macOS under KVM on an Apple-silicon Linux host.
#
# Under KVM, macOS's GIC driver initializes each redistributor with `str w9, [x8, #128]!`, a
# pre-indexed store with no syndrome (ISV=0). KVM cannot emulate it, and the vGIC it targets is
# KVM's own, so QEMU cannot either: the guest takes an external abort and panics early. This
# bundle carries one Ambrosia `Kernel > Patch` for com.apple.kernel that rewrites the four
# instructions to two plain stores at the same addresses with the same values:
#
#   Find    09c0af12 090d08b8 0900a152 098100b9   mov w9,#0x81ffffff; str w9,[x8,#128]!; mov w9,#0x8000000; str w9,[x8,#128]
#   Replace 09c0af12 098100b9 0900a152 090101b9   mov w9,#0x81ffffff; str w9,[x8,#128];  mov w9,#0x8000000; str w9,[x8,#256]
#
# Matched once in macOS 27.0.1 (26A434) and 27.2.1 (26B131). With -b, the bundle is reims-vgpu's
# staged configuration (firmware/ambrosia/build/config after `make config-bundle`) with the patch
# added; without it, a bundle of config.plist alone. Packed as reims-vgpu's Makefile packs
# Config.cpio: cpio newc, config.plist first, then Drivers and Kexts in sorted order.
#
# usage: scripts/make-kvm-bundle.sh [-b STAGED_CONFIG_DIR] [-v] [-f] OUT.cpio
#   -b DIR  reims-vgpu's staged configuration directory (holds config.plist, Drivers, Kexts)
#   -v      also set BootArgs to `serial=3 -v` (a verbose boot; reims' check-boot wants none)
#   -f      replace OUT.cpio if it exists
set -euo pipefail

die() { echo "make-kvm-bundle: $*" >&2; exit 2; }
base='' verbose=0 force=0
while getopts b:vfh opt; do
  case $opt in
    b) base=$OPTARG ;;
    v) verbose=1 ;;
    f) force=1 ;;
    *) sed -n '2,23p' "$0"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# == 1 ]] || die "give one OUT.cpio"
out=$1
[[ $out == *.cpio ]] || die "OUT must end in .cpio"
[[ ! -e $out || $force == 1 ]] || die "$out exists (use -f to replace it)"
for t in python3 cpio find sort; do command -v "$t" > /dev/null || die "needs $t"; done
if [[ -n $base ]]; then
  [[ -f $base/config.plist && -d $base/Drivers && -d $base/Kexts ]] ||
    die "$base is not a staged configuration (config.plist, Drivers, Kexts)"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/make-kvm-bundle.XXXXXX")
trap 'rm -rf "$work"' EXIT
stage=$work/stage
mkdir -p "$stage"
[[ -n $base ]] && cp -R "$base"/. "$stage"/

BASE_PLIST=${base:+$base/config.plist} VERBOSE=$verbose python3 -I - "$stage/config.plist" <<'EOF'
import os, plistlib, sys
out = sys.argv[1]
src = os.environ.get("BASE_PLIST")
cfg = plistlib.load(open(src, "rb")) if src else {}
patch = {
    "Identifier": "com.apple.kernel",
    "Find": bytes.fromhex("09c0af12090d08b80900a152098100b9"),
    "Replace": bytes.fromhex("09c0af12098100b90900a152090101b9"),
}
patches = cfg.setdefault("Kernel", {}).setdefault("Patch", [])
if any(p.get("Find") == patch["Find"] for p in patches):
    sys.exit("make-kvm-bundle: the configuration already has the GIC patch")
patches.append(patch)
if os.environ["VERBOSE"] == "1":
    cfg["BootArgs"] = "serial=3 -v"
with open(out, "wb") as f:
    plistlib.dump(cfg, f, fmt=plistlib.FMT_XML)
EOF

tmp_out=$work/out.cpio
(cd "$stage" && {
  echo config.plist
  [[ -d Drivers ]] && find Drivers -type f | LC_ALL=C sort
  [[ -d Kexts ]] && find Kexts -type f | LC_ALL=C sort
  true
} | cpio -o -H newc --quiet > "$tmp_out")
mv -f "$tmp_out" "$out"
echo "make-kvm-bundle: $out ($(wc -c < "$out") bytes, sha256 $(sha256sum < "$out" | cut -c1-16))"
