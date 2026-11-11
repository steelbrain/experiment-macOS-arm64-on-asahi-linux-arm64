#!/usr/bin/env bash
# Runs reims-vgpu's own boot check, firmware/ambrosia/check-boot.sh, under KVM.
#
# check-boot.sh knows HVF and TCG (-t) only. This writes a copy of the pinned script next to its
# logs with four exact substitutions, each required to match exactly once, and runs the copy with
# -t, so that TCG's Linux setup applies unchanged: the guest's RAM as a shared memfd, the longer
# limits, and every check as -t judges it. The substitutions:
#   1. `here=` points at the original script's directory (for tools/stage-config.py);
#   2. -t's `-accel tcg,thread=multi` becomes `-accel kvm -cpu host,pmu=off,kvm-psci-version=1.1`
#      (vmapple does not initialize a PMU, and KVM refuses a vCPU that asks for one; KVM offers
#      PSCI 1.3, which macOS's ApplePSCI rejects, leaving the secondary vCPUs unstarted);
#   3. `-smp 4` becomes `-smp $SMP` (default 4);
#   4. the run's first line says KVM rather than TCG.
# Nothing in reims-vgpu's tree is changed.
#
# usage: scripts/check-boot-kvm.sh [check-boot.sh options, without -t] VM_DIR
# env:   REIMS (WORK/reims-vgpu), WORK (~/work), SMP (4)
set -euo pipefail

die() { echo "check-boot-kvm: $*" >&2; exit 2; }
REIMS=${REIMS:-${WORK:-$HOME/work}/reims-vgpu}
SMP=${SMP:-4}
src=$REIMS/firmware/ambrosia/check-boot.sh
[[ -f $src ]] || die "no $src"
[[ $SMP =~ ^[0-9]+$ ]] || die "SMP must be a number"
[[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not usable"

work=$(mktemp -d "${TMPDIR:-/tmp}/check-boot-kvm.XXXXXX")
copy=$work/check-boot-kvm.sh
here_dir=$(cd "$(dirname "$src")" && pwd)

# subst FROM TO: replace the one line holding FROM (a fixed string) with TO's substitution.
subst() {
  local from=$1 to=$2 n
  n=$(grep -cF -- "$from" "$copy" || true)
  [[ $n == 1 ]] || die "expected one line with '$from' in $src, found $n: the script changed"
  FROM=$from TO=$to perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$copy"
}

cp "$src" "$copy"
subst 'here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)' "here=$here_dir"
subst 'accel=(-accel tcg,thread=multi)' 'accel=(-accel kvm -cpu host,pmu=off,kvm-psci-version=1.1)'
subst '-smp 4 -bios' "-smp $SMP -bios"
subst '&& echo TCG ||' "&& echo \"KVM ($SMP vCPU, -t limits)\" ||"
chmod +x "$copy"
echo "check-boot-kvm: $(sha256sum < "$src" | cut -c1-16) $src -> $copy"
exec "$copy" -t "$@"
