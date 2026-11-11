# Repository working agreement

## Objective

Boot an installed macOS arm64 virtual machine on Apple Silicon running Asahi
Linux, under KVM in QEMU's `vmapple` machine, on Ambrosia firmware, displaying
through reims-vgpu.

## Working rules

- Treat this repository as an experimental lab. Prefer small, inspectable
  scripts and reproducible commands over undocumented manual steps.
- Keep `README.md` current: it documents the working flow, its pinned commits
  and its verified results, with exact versions.
- Never commit Apple firmware, IPSWs, restore images, VM disks, machine
  identifiers, or other large/proprietary artifacts. Keep them under `artifacts/`
  or outside the repository; `.gitignore` must cover them.
- Standing authorization: autonomously execute actions reasonably required to
  reach the repository objective without requesting further approval. This
  includes downloads, sparse-disk allocation, package changes, kernel-module
  operations, task-scoped permission changes, and restarting experiment
  processes. Continue reporting material sizes, purposes, and host mutations
  before or as they occur so the work remains auditable.
- Keep host changes narrowly scoped to this objective and avoid irreversible or
  unrelated destructive actions even under the standing authorization.
- Scripts must use `set -euo pipefail`, quote paths, validate prerequisites, and
  default to non-destructive behavior.
- Capture upstream URLs and commit IDs for QEMU, firmware and other sources.
  Pin known working revisions instead of silently tracking a moving branch.

## Definition of done

The repository contains a reproducible, documented flow that:

1. verifies the Asahi/KVM host,
2. builds QEMU with `vmapple` and reims-vgpu, and Ambrosia, from pinned commits,
3. boots a user-supplied, already installed macOS VM,
4. launches the guest with KVM and persistent logging, and
5. reaches the macOS desktop.
