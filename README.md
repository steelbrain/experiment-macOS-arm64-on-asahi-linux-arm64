# macOS on Asahi Linux KVM

Boots an installed arm64 macOS guest under KVM on an Apple Silicon Mac running
Asahi Linux. The guest runs in QEMU's `vmapple` machine on
[Ambrosia](https://github.com/steelbrain/ambrosia), which replaces Apple's
AVPBooter and iBoot. It displays through
[reims-vgpu](https://github.com/steelbrain/reims-vgpu)'s `reims-graphics-pci`
device, which renders with Vulkan on the host's GPU.

This repository holds the scripts that build the pinned sources, add the one
KVM-specific boot patch, and boot or check a guest. This is research code, not
a virtual-machine product.

## Status (2026-11-11)

Host: an M2 Pro on Fedora Asahi Remix 42, with the stock Asahi kernel
`6.19.14-400.asahi.fc42` (not patched) and Mesa 25.3.6, whose Vulkan driver
for the GPU is Honeykrisp.

Built by `scripts/build.sh` from an empty `$WORK` at the pins below, both guests
pass all 15 checks of reims-vgpu's `firmware/ambrosia/check-boot.sh` under KVM
with 4 vCPUs, run through `scripts/check-boot-kvm.sh`:

| Guest | Checks | SSH login after QEMU starts | Metal app, 10 s on screen |
| --- | --- | --- | --- |
| macOS 27.0.1 (26A434) | 15 of 15 | 21.7 s | 601 frames presented, none dropped, 60.0 fps |
| macOS 27.2.1 (26B131) | 15 of 15 | 27.4 s | 599 frames presented, none dropped, 59.8 fps |

- The desktop renders on the M2 Pro's GPU. QEMU's screendump shows Finder's
  menu bar and the Dock (27.0.1: 480,673 distinct colours; the check fails a
  screen of one colour).
- System Integrity Protection is enabled and `kern.bootargs` is empty.
  reims-vgpu's kexts (ReimsGraphics, RgfxGate, Graft) load, and WindowServer's
  Metal device is `Apple M2 Pro (G14S B1)`.
- The 27.2.1 guest shows macOS's Keyboard Setup Assistant at login, because
  it does not recognise QEMU's keyboard. The dialog sits over the desktop and
  does not affect the checks.
- The 27.0.1 guest was first copied with `scripts/prepare-guest-nominibuddy.sh`
  (step 4). A copy made the same way from a guest directory holding `aux.img`
  (the trimmed image with 16 KiB in front) instead of `aux.img.trimmed` also
  passes 15 of 15.

## Pinned sources

`scripts/build.sh` clones and builds these commits:

| Source | Commit |
| --- | --- |
| reims-vgpu `development` | `6179228984e33c643799b2249f5a5f6bea1d1fac` |
| its `vendor/qemu` ([qemu-reims-vgpu](https://github.com/steelbrain/qemu-reims-vgpu)) | `b95dc452f7087ec21c9bb3787518a81aee53e62a` |
| [metal2vulkan](https://github.com/steelbrain/metal2vulkan), as reims-vgpu's `Cargo.toml` names it | `30cadd8dda54670522e0d9dce59205fe7c84a023` |
| Ambrosia v0.1.2 | `db6aa658fef8f20097d6a24fe85536bfecfc15d8` |

## What KVM needs

macOS was built for Apple's hypervisor, and some of what it expects differs
under KVM. These are the differences, and where each is handled:

| Under KVM | Handled by |
| --- | --- |
| KVM refuses a vCPU that asks for a PMU, and `vmapple` does not set one up | QEMU `5093524e`: `vmapple` sets `pmu=off` under KVM |
| KVM offers PSCI 1.3, which macOS's ApplePSCI rejects, so no secondary vCPU starts | QEMU `5093524e`: `vmapple` sets `kvm-psci-version=1.1` under KVM |
| KVM handles PSCI `CPU_ON` itself, so secondary vCPUs start without the boot vCPU's pointer-authentication keys | QEMU `570daa78`, `da466bd8`: KVM's SMCCC filter forwards `CPU_ON` to QEMU, which starts the vCPU |
| KVM answers macOS's pointer-authentication hypercalls (SMCCC 0xC1000000-0xC10000FF) by zeroing x1-x3; XNU keeps x3, and launchd dies on a PAC failure | QEMU `bd5ac1ce`, `4dca14b4`: the calls are forwarded and answered as TCG and HVF answer them |
| A device-memory access with writeback faults with no syndrome (ISV=0), which KVM cannot emulate | QEMU `89e32906`, `3892a92f`: HVF's ISV=0 MMIO emulator, shared with KVM. reims-vgpu's firmware graphics driver and Ambrosia v0.1.2 also use only plain loads and stores on device memory |
| XNU's GIC driver writes each redistributor with a pre-indexed store (ISV=0) into KVM's own vGIC, which QEMU cannot emulate either | `scripts/make-kvm-bundle.sh`: an Ambrosia `Kernel > Patch` turns those four instructions into two plain stores with the same addresses and values. The guest disk is not modified |

The QEMU commits are in reims-vgpu's `vendor/qemu` at the pinned commit.

The host GPU's Vulkan driver, Honeykrisp in Mesa 25.3.6, lacks
`VK_EXT_rasterization_order_attachment_access`,
`VK_EXT_fragment_shader_interlock` and `VK_EXT_external_memory_host`.
metal2vulkan at the pinned commit reads CoreAnimation's framebuffer fetch as an
input attachment, and imports no-copy buffers from the guest pages' dma-bufs,
so nothing the desktop draws is refused.

## Requirements

- An Apple Silicon Mac running Asahi Linux with a kernel whose Asahi DRM
  interface Mesa 25.3 supports. Tested: an M2 Pro on Fedora Asahi Remix 42
  with `kernel-16k-6.19.14-400.asahi.fc42`, unpatched. Its 6.14.2 kernel was
  too old for Mesa 25.3's Asahi Vulkan driver, which then found no GPU.
- `/dev/kvm` and `/dev/udmabuf` usable by your user. On Fedora both belong to
  the `kvm` group: `sudo usermod -aG kvm "$USER"`, then log in again.
- Build packages and rustup. On Fedora Asahi Remix 42:

  ```sh
  sudo dnf install -y --skip-unavailable gcc gcc-c++ make git curl pkgconf-pkg-config python3 \
    ninja-build meson flex bison bzip2 cmake binutils glib2-devel pixman-devel libslirp-devel \
    zlib-ng-compat-devel libfdt-devel pipewire-devel pulseaudio-libs-devel alsa-lib-devel \
    libusb1-devel spice-server-devel vulkan-loader vulkan-loader-devel vulkan-tools \
    mesa-vulkan-drivers libX11-devel libXext-devel libXrandr-devel libXcursor-devel libXi-devel \
    libXfixes-devel libXScrnSaver-devel libXtst-devel libxkbcommon-devel wayland-devel \
    libdecor-devel mesa-libEGL-devel mesa-libGL-devel libdrm-devel mesa-libgbm-devel dbus-devel \
    systemd-devel gtk3-devel gnutls-devel libva-devel clang lld cpio sshpass perl python3-pip jq
  curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none --profile minimal
  ```

  reims-vgpu's `rust-toolchain.toml` selects its toolchain.
- An installed arm64 macOS VM. This repository does not install or restore
  macOS: supply a VM that has already been installed or restored, as a
  directory holding:
  - `disk.img`, the installed system disk, raw;
  - `aux.img`, the VM's auxiliary storage, or `aux.img.trimmed`, the same
    without its first 16 KiB;
  - `vm.toml`, with the line `ecid = <the VM's ECID in decimal>`.

  Tested with macOS 27.0.1 (26A434) and 27.2.1 (26B131). The scripts boot
  reflink clones of the disks, so the directory must be on a filesystem with
  reflinks (btrfs on Fedora Asahi Remix), and the guest's own files are never
  written.
- For the boot check only: reims-vgpu's guest probes `bench` and
  `present_probe`, which build with Xcode on a Mac, from a checkout of
  reims-vgpu at the pinned commit:
  `make -C firmware/ambrosia guest-tools`, then copy
  `firmware/ambrosia/build/guest-tools` to the host.
- Disk space: the guest's sparse disk, a reflink clone per boot, and about
  13 GiB for the builds: the reims-vgpu tree 7.3 GiB, cargo's cache 3.9 GiB
  and the Rust toolchains 1.7 GiB.

Do not commit or share guest files: the disk holds an installed copy of macOS,
and the auxiliary storage and ECID identify the VM.

## 1. Build

On the Asahi host, from a clone of this repository:

```sh
CONFIRM=1 scripts/build.sh
scripts/check-host.sh
```

`build.sh` clones the pinned sources into `$WORK` (default `~/work`), refuses a
checkout at any other commit or with local changes, and builds them without
patches: reims-vgpu's library, `qemu-system-aarch64` with KVM, TCG and
`reims-graphics-pci`, `ambrosia.bin`, and reims-vgpu's Ambrosia configuration
(its early-console module, Graft, ReimsGraphics and RgfxGate). Logs go to
`$WORK/logs`.

`check-host.sh` checks the architecture, `/dev/kvm`, that the built QEMU has
the `vmapple` machine and KVM, and `/dev/udmabuf`.

## 2. Make the KVM configuration bundle

```sh
scripts/make-kvm-bundle.sh -b ~/work/reims-vgpu/firmware/ambrosia/build/config \
  ~/work/reims-kvm.cpio
```

This adds the GIC `Kernel > Patch` to reims-vgpu's staged configuration and
packs it as reims-vgpu's Makefile packs `Config.cpio`. `-v` also sets
`BootArgs` to `serial=3 -v` for a verbose boot. The patch's pattern occurs
once in macOS 27.0.1 and once in 27.2.1.

## 3. Boot

```sh
scripts/boot-ambrosia.sh -b ~/work/reims-kvm.cpio -o logs/boot-1 ~/guests/macos
```

QEMU runs in the foreground under KVM with 4 vCPUs and 8 GiB of RAM, on
reflink clones of the guest's disks. Stop it with Ctrl-C or with QMP `quit` on
`OUT/qmp.sock`. Serial, QEMU and QMP logs go to the `-o` directory, and the
guest's SSH is forwarded to host port 10090 (`-p`). `-a tcg` boots the same
guest under TCG.

## 4. Run reims-vgpu's boot check under KVM

```sh
GUEST_USER=... GUEST_PASS=... scripts/check-boot-kvm.sh \
  -f ~/work/ambrosia/target/ambrosia.bin \
  -q ~/work/reims-vgpu/build/qemu-aarch64/qemu-system-aarch64 \
  -b ~/work/reims-kvm.cpio -T ~/guest-tools \
  -o ~/work/logs/check-1 ~/guests/macos
```

reims-vgpu's `firmware/ambrosia/check-boot.sh` knows only HVF and TCG.
`check-boot-kvm.sh` writes a copy of it next to the logs with four exact
substitutions and runs the copy with `-t`: the accelerator becomes KVM, the
vCPU count `$SMP` (default 4), and the run's first line says KVM. The
reims-vgpu tree is not changed. The check boots the guest, logs in over SSH,
and runs 14 checks, from the firmware's console to an on-screen Metal app's
presented frames.

If Setup Assistant opens at the guest's login, it covers the session, and the
check reports the Metal app as unread. Make a copy of the guest without it
first. This boots a clone, runs reims-vgpu's
`scripts/internal/guest-minibuddy-off.sh` in it, and keeps the clone:

```sh
GUEST_USER=... GUEST_PASS=... scripts/prepare-guest-nominibuddy.sh \
  -b ~/work/reims-kvm.cpio ~/guests/macos ~/guests/macos-nominibuddy
```

To render with Mesa's llvmpipe instead of the GPU, set
`VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.aarch64.json`.

## Known issue: GPU memory kept after QEMU exits

The Asahi kernel GPU driver keeps some of the guest-memory dma-bufs that
reims-vgpu imports, after they are freed and after QEMU exits. Each of the four
boots behind the status above left between 1.7 and 2.9 GB pinned, and only a
host reboot frees it. The last line of `/sys/kernel/debug/dma_buf/bufinfo`
shows the total. Reboot the host before its free memory runs low.

A C program that only imports and frees udmabufs through Vulkan, with no QEMU
or guest, loses them the same way, even from one thread. Kernel traces show
each kept buffer's GPU VM binding (`drm_gpuvm_bo`) on its VM's deferred-free
list, never destroyed. The driver cleaned that list only during later ioctls,
and not when the VM was torn down.

## Project boundaries

- Never commit firmware, IPSWs, restore images, VM disks, VM identities, or
  logs. The repository's ignore rules cover the expected locations and
  formats.
- This project does not redistribute macOS or bypass Apple's restore signing.
- Kernel and hypervisor experiments can crash or reboot the host. Keep a
  working kernel boot entry and backups of anything important.
- There is no support promise. Reproduction reports with exact host, kernel,
  QEMU, firmware, and guest versions are welcome.
