#!/usr/bin/env bash
# Checks that this host can run the guest: an aarch64 Linux kernel with /dev/kvm usable by this
# user, scripts/build.sh's QEMU with the vmapple machine and KVM, and /dev/udmabuf, which
# reims-vgpu maps guest pages through.
#
# usage: scripts/check-host.sh
# env:   QEMU (default: scripts/build.sh's, under WORK), WORK (~/work)
set -euo pipefail

die() { echo "check-host: $*" >&2; exit 1; }
WORK=${WORK:-$HOME/work}
QEMU=${QEMU:-$WORK/reims-vgpu/build/qemu-aarch64/qemu-system-aarch64}

[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] || die "this needs an aarch64 Linux host"
[[ -r /dev/kvm && -w /dev/kvm ]] || die "$(id -un) cannot use /dev/kvm"
[[ -x $QEMU ]] || die "no QEMU at $QEMU (run scripts/build.sh, or set QEMU)"
machines=$("$QEMU" -machine help)
accels=$("$QEMU" -accel help)
grep -q '^vmapple ' <<< "$machines" || die "$QEMU has no vmapple machine"
grep -qx kvm <<< "$accels" || die "$QEMU was built without KVM"
[[ -e /dev/udmabuf ]] || die "no /dev/udmabuf (load the udmabuf module)"
[[ -r /dev/udmabuf && -w /dev/udmabuf ]] ||
  die "$(id -un) cannot use /dev/udmabuf (add the user to its group, kvm on Fedora)"

printf 'architecture: %s\n' "$(uname -m)"
printf 'kernel: %s\n' "$(uname -r)"
printf 'QEMU: %s\n' "$QEMU"
printf 'KVM, vmapple, udmabuf: usable\n'
