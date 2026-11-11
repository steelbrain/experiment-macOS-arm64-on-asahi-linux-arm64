#!/usr/bin/env bash
# Builds everything the guest runs on, on an Asahi Linux (aarch64) host, at pinned commits:
#
#   1. reims-vgpu's library on its Vulkan platform (`make` = `cargo xtask dist`,
#      target/dist-vulkan), with metal2vulkan at the commit reims-vgpu's Cargo.toml names;
#   2. reims-vgpu's vendor/qemu as qemu-system-aarch64 with KVM, TCG and reims-graphics-pci;
#   3. Ambrosia, the boot firmware (target/ambrosia.bin);
#   4. reims-vgpu's configuration bundle for Ambrosia (firmware/ambrosia/build/Config.cpio and the
#      staged firmware/ambrosia/build/config): its early-console module, Graft, ReimsGraphics and
#      RgfxGate, from guest/prebuilt-arm64e.
#
# Sources are cloned from GitHub into $WORK at the pinned commits. A checkout at another commit,
# or with local changes, is refused. Nothing is patched. Logs go to $WORK/logs.
#
# usage: CONFIRM=1 scripts/build.sh
# env:   WORK ($HOME/work), REIMS_REV, QEMU_REV, AMBROSIA_REV, JOBS (nproc)
set -euo pipefail

die() { echo "build: $*" >&2; exit 1; }
[[ ${CONFIRM:-0} == 1 ]] || die "builds several GiB under \$WORK (${WORK:-$HOME/work}); rerun with CONFIRM=1"
[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] || die "run this on an aarch64 Linux host"

WORK=${WORK:-$HOME/work}
REIMS_REV=${REIMS_REV:-6179228984e33c643799b2249f5a5f6bea1d1fac}    # reims-vgpu development
QEMU_REV=${QEMU_REV:-b95dc452f7087ec21c9bb3787518a81aee53e62a}      # its vendor/qemu
AMBROSIA_REV=${AMBROSIA_REV:-db6aa658fef8f20097d6a24fe85536bfecfc15d8} # Ambrosia v0.1.2
JOBS=${JOBS:-$(nproc)}
LOGS=$WORK/logs
mkdir -p "$WORK" "$LOGS"
[[ -f $HOME/.cargo/env ]] && . "$HOME/.cargo/env"
for t in git make cargo rustup clang ld.lld cpio python3 pkg-config ninja meson; do
  command -v "$t" > /dev/null || die "needs $t"
done

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# clone_at URL DIR REV: a clone of URL in DIR at REV, refusing a dirty or other checkout.
clone_at() {
  local url=$1 dir=$2 rev=$3
  [[ -d $dir/.git ]] || git clone -q "$url" "$dir"
  git -C "$dir" cat-file -e "$rev^{commit}" 2> /dev/null || git -C "$dir" fetch -q origin
  [[ -z $(git -C "$dir" status --porcelain --untracked-files=no) ]] || die "$dir has local changes"
  git -C "$dir" checkout -q --detach "$rev"
  [[ $(git -C "$dir" rev-parse HEAD) == "$rev" ]] || die "$dir is not at $rev"
}

R=$WORK/reims-vgpu
A=$WORK/ambrosia
# Cargo may rewrite reims-vgpu's Cargo.lock during the library build (it adds the `source` lines of
# metal2vulkan's git dependency when they are missing). Drop that generated change so clone_at's
# check sees only edits made by hand.
if [[ -d $R/.git ]]; then git -C "$R" checkout -q -- Cargo.lock 2> /dev/null || true; fi
clone_at https://github.com/steelbrain/reims-vgpu.git "$R" "$REIMS_REV"
git -C "$R" submodule update --init --filter=blob:none vendor/qemu
[[ $(git -C "$R/vendor/qemu" rev-parse HEAD) == "$QEMU_REV" ]] ||
  die "vendor/qemu is at $(git -C "$R/vendor/qemu" rev-parse HEAD), not $QEMU_REV"
[[ -z $(git -C "$R/vendor/qemu" status --porcelain --untracked-files=no) ]] || die "vendor/qemu has local changes"
clone_at https://github.com/steelbrain/ambrosia.git "$A" "$AMBROSIA_REV"
log "sources: reims-vgpu $REIMS_REV, vendor/qemu $QEMU_REV, ambrosia $AMBROSIA_REV"
log "metal2vulkan: $(grep -m1 -o 'metal2vulkan", rev = "[0-9a-f]*"' "$R/Cargo.toml" || echo unknown)"

log "library: make (cargo xtask dist)"
make -C "$R" > "$LOGS/library.log" 2>&1 || { tail -40 "$LOGS/library.log"; die "library build failed ($LOGS/library.log)"; }
git -C "$R" checkout -q -- Cargo.lock 2> /dev/null || true # cargo's source lines, as above

log "qemu-system-aarch64: configure and build"
Q=$R/build/qemu-aarch64
mkdir -p "$Q"
if [[ ! -f $Q/build.ninja ]]; then
  (cd "$Q" && PKG_CONFIG_PATH="$R/target/dist-vulkan/lib/pkgconfig" "$R/vendor/qemu/configure" \
    --target-list=aarch64-softmmu --enable-kvm --enable-tcg --enable-reims-vgpu --enable-gnutls \
    --enable-slirp --disable-docs --disable-bsd-user --disable-linux-user --disable-tools) \
    > "$LOGS/qemu-configure.log" 2>&1 || { tail -40 "$LOGS/qemu-configure.log"; die "configure failed"; }
fi
grep -E 'reims-vgpu support|KVM support|TCG support|slirp support|GNUTLS support' "$LOGS/qemu-configure.log" || true
make -C "$Q" -j"$JOBS" qemu-system-aarch64 > "$LOGS/qemu-build.log" 2>&1 ||
  { tail -40 "$LOGS/qemu-build.log"; die "QEMU build failed ($LOGS/qemu-build.log)"; }

log "ambrosia: make"
make -C "$A" > "$LOGS/ambrosia.log" 2>&1 || { tail -40 "$LOGS/ambrosia.log"; die "Ambrosia build failed"; }

log "configuration bundle: module, Graft, ReimsGraphics, RgfxGate (arm64e prebuilt)"
P=$R/guest/prebuilt-arm64e
make -C "$R/firmware/ambrosia" config-bundle GRAFT="$P/Graft-arm64e.kext" \
  REIMS_GRAPHICS="$P/ReimsGraphics.kext" RGFXGATE="$P/RgfxGate.kext" > "$LOGS/bundle.log" 2>&1 ||
  { tail -40 "$LOGS/bundle.log"; die "bundle build failed"; }

log "products:"
sha256sum "$Q/qemu-system-aarch64" "$A/target/ambrosia.bin" "$R/firmware/ambrosia/build/Config.cpio" \
  "$R/target/dist-vulkan/lib/libreims_vgpu.a"
"$Q/qemu-system-aarch64" --version | head -1
