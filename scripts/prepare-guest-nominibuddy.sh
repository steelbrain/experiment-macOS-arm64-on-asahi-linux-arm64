#!/usr/bin/env bash
# Makes a copy of a macOS guest whose login does not open Setup Assistant's MiniBuddy panes
# ("Sign In to Your Apple Account" and the like), so that reims-vgpu's check-boot can read its
# metal-app check. Setup Assistant covers the session with a full-screen window, and check-boot
# reports metal-app as "unread" while it runs.
#
# The source guest is not changed. This boots reflink clones of its disks with boot-ambrosia.sh -k,
# runs reims-vgpu's scripts/internal/guest-minibuddy-off.sh in the guest over SSH (it deletes
# com.apple.loginwindow MiniBuddyLaunch for any host and for this host), shuts the guest down from
# inside, and moves the clones to DEST_DIR with the source's vm.toml.
#
# usage: GUEST_USER=... GUEST_PASS=... scripts/prepare-guest-nominibuddy.sh [-c CPUS] [-b BUNDLE]
#          [-p PORT] SRC_DIR DEST_DIR
# env:   QEMU, AMBROSIA (as boot-ambrosia.sh), REIMS (WORK/reims-vgpu), WORK (~/work)
set -euo pipefail

die() { echo "prepare-guest-nominibuddy: $*" >&2; exit 1; }
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cpus=4 bundle='' port=10129
while getopts c:b:p:h opt; do
  case $opt in
    c) cpus=$OPTARG ;; b) bundle=$OPTARG ;; p) port=$OPTARG ;;
    *) sed -n '2,15p' "$0"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# == 2 ]] || die "give SRC_DIR and DEST_DIR"
src=$(cd "$1" && pwd) || die "no $1"
dest=$2
: "${GUEST_USER:?set GUEST_USER}" "${GUEST_PASS:?set GUEST_PASS}"
WORK=${WORK:-$HOME/work}
REIMS=${REIMS:-$WORK/reims-vgpu}
mb=$REIMS/scripts/internal/guest-minibuddy-off.sh
[[ -f $mb ]] || die "no $mb"
[[ ! -e $dest ]] || die "$dest exists"
[[ -f $src/vm.toml ]] || die "no $src/vm.toml"
[[ -f $here/qmp.py ]] || die "no $here/qmp.py"
for t in sshpass ssh python3; do command -v "$t" > /dev/null || die "needs $t"; done

out=$WORK/logs/prep-nominibuddy-$(date -u +%Y%m%dT%H%M%SZ)
G() {
  sshpass -p "$GUEST_PASS" ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o LogLevel=ERROR "$GUEST_USER@127.0.0.1" "$@"
}

b=()
[[ -n $bundle ]] && b=(-b "$bundle")
"$here/boot-ambrosia.sh" -a kvm -c "$cpus" "${b[@]}" -p "$port" -o "$out" -k "$src" &
qpid=$!
# On any failure, end QEMU through QMP (killing the wrapper would leave QEMU running); its clones
# then stay in OUT/clone for a look.
stop_qemu() {
  [[ -S $out/qmp.sock ]] && python3 -I "$here/qmp.py" "$out/qmp.sock" '{"execute": "quit"}' > /dev/null 2>&1
  wait "$qpid" 2> /dev/null || true
}
trap stop_qemu EXIT

ok=0
for _ in $(seq 1 60); do
  kill -0 "$qpid" 2> /dev/null || die "QEMU exited before SSH came up (logs in $out)"
  if G true 2> /dev/null; then ok=1; break; fi
  sleep 5
done
((ok)) || die "no SSH in 300 s (logs in $out)"
echo "prepare-guest-nominibuddy: guest $(G 'sw_vers -productVersion; sw_vers -buildVersion' | paste -sd' ')"

# MiniBuddy comes up about 10 s after login; give it time, as check-boot does before reading it.
sleep 30
rc=0
G 'bash -s' < "$mb" || rc=$?
case $rc in
  0 | 3) ;;
  *) die "guest-minibuddy-off.sh exited $rc (logs in $out)" ;;
esac
G "echo '$GUEST_PASS' | sudo -S -p '' sync" || true
G "echo '$GUEST_PASS' | sudo -S -p '' shutdown -h now" || true
for _ in $(seq 1 60); do
  kill -0 "$qpid" 2> /dev/null || break
  sleep 2
done
if kill -0 "$qpid" 2> /dev/null; then
  die "the guest did not power off in 120 s; the clones stay in $out/clone"
fi
wait "$qpid" || true
trap - EXIT

mkdir -p "$(dirname "$dest")"
mkdir "$dest"
mv "$out/clone/disk.img" "$out/clone/aux.img.trimmed" "$dest/"
rmdir "$out/clone"
cp -p "$src/vm.toml" "$dest/vm.toml"
echo "prepare-guest-nominibuddy: $dest (MiniBuddy off; boot logs in $out)"
