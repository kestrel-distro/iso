# Kestrel ISO

Builds the Kestrel live image: the graphical session you boot to try Kestrel and
to install it.

The live session is a full Kestrel desktop, not a text installer. The installer
writes the running system to the target disk by copying it, so the machine you
end up with is the machine you were just using. This is the casper/anaconda
model rather than the Arch package-by-package model: there is no second
definition of "what Kestrel is" to drift from the one you tested, and no package
repository has to ride along on the medium.

The live image boots `linux-kestrel` (the stock Arch kernel is not in the
package set). It carries the hint bridge, `scx_kestrel`, the shared foot server
and the desktop defaults.

## How an install works

- The ISO boots the Kestrel desktop as a dedicated `kestrel` live user
  (autologin, passwordless sudo, fish login shell).
- **Install Kestrel** is at the root of the Super+D menu. The configurator asks
  for keyboard, account, hostname, timezone and disk with plain numbered/text
  prompts, then installs.
- The wizard can install encrypted (default), unencrypted, into free space
  alongside another OS, or prepare the machine for another owner and defer
  account setup to first boot.
- The installer partitions (GPT: bios_grub + ESP + root), sets up LUKS2 + Btrfs
  subvolumes (`@`, `@home`, `@log`, `@pkg`), copies the live rootfs, runs the
  target setup in a chroot (locale, user, bootloader, initramfs) and reboots.
- The install log is written live to the VM host share
  (`/mnt/kestrel-host-logs/kestrel-install.log`) from the first prompt, so a
  freeze or a killed terminal leaves the last phase behind. On real hardware it
  stays at `/var/log/kestrel-install.log`.
- Nothing is installed from a network repository. Everything the installer
  needs is in the image; the live session may use the network only for optional
  hardware-specific packages.

## Creating the ISO

```bash
./bin/kestrel-iso-make                 # build release/<name>.iso
./bin/kestrel-iso-make --local-source   # build from ../kestrel and ../kernel
./bin/kestrel-iso-make --no-boot-offer
```

The builder runs `builder/build-iso.sh` inside an `archlinux/archlinux`
container. It upgrades the container, resolves the Arch package set from the
payload's `install/*.packages`, builds the AUR and source packages the payload
needs, downloads the bundled Node tarball, and assembles the squashfs and boot
loaders.

`--local-source` builds the payload from the sibling `../kestrel` checkout
(default when it exists) instead of cloning, mounts the sibling `../kernel`
checkout as `/kernel`, and ships its `bench/` harness under
`/usr/share/kestrel-bench/bench`. The live bench then never clones from GitHub.
`--no-cache` ignores the caches; `--no-boot-offer` skips the boot prompt.

Caches live under `~/.cache/kestrel/`: `pacman-pkg/` for Arch packages and
`aur-packages/` for AUR/source builds. They persist across runs; a complete
cache skips the corresponding build. The kernel source package is reused when
`/data/kestrel-iso-build/work/aur-repo/linux-kestrel.rev` matches the kernel
repository HEAD.

### Environment variables

| Variable | Meaning |
|---|---|
| `KESTREL_PATH` | Payload checkout used with `--local-source` (default `../kestrel`). |
| `KERNEL_PATH` | Kernel checkout mounted for the bench harness (default `../kernel`). |
| `KESTREL_INSTALLER_REPO` | GitHub payload repository (default `kestrel-distro/kestrel`). |
| `KESTREL_INSTALLER_REF` | Payload git ref (default `main`); ignored with `--local-source`. |
| `KESTREL_BUILD_DIR` | Heavy scratch directory (default `/data/kestrel-iso-build`). |
| `KESTREL_VM_GL` | Set to `1` on `kestrel-iso-boot` to use `virtio-vga-gl`. |

## Testing the ISO

```bash
./bin/kestrel-iso-boot release/<image>.iso
```

The helper installs `qemu-full` and `edk2-ovmf` if missing, creates a 20 GiB
scratch disk under `/data/kestrel-vm`, and boots under UEFI. It captures the
serial console, qemu log and a host 9p share in `~/.cache/kestrel/vm-logs/`; the
guest mounts the share at `/mnt/kestrel-host-logs`.

The VM display defaults to the 2D `virtio-vga` device. `virtio-vga-gl` routes 3D
through the host EGL driver and has crashed QEMU in `libnvidia-eglcore`; use
`KESTREL_VM_GL=1` only on a host where that path is known good. This is the only
supported way to exercise an install: do not run the installer against your own
machine.

## Signing and releasing

```bash
./bin/kestrel-iso-sign [gpg-user] [release/iso]   # detached signature
./bin/kestrel-iso-release                          # build + sign + checksum
./bin/kestrel-iso-flash <iso>                      # write to USB (+ vault COW)
```

## Repository layout

| Path | Contents |
|---|---|
| `builder/build-iso.sh` | the in-container build |
| `configs/` | archiso profile, boot configs, live-only airootfs files (installer, configurator, live init, VM report) |
| `configs/airootfs/root/configurator` | the interactive answers wizard |
| `configs/airootfs/usr/local/bin/kestrel-install` | partitioning, copy, target setup, logging |
| `configs/airootfs/usr/local/lib/` | live init, target setup, host-log mount |
| `bin/` | `kestrel-iso-make`, `-boot`, `-sign`, `-release`, `-flash`, `-vault` |
| `archiso/` | vendored upstream archiso (submodule) |
| `release/` | build output (ignored) |

## License

Released under the MIT License. See [LICENSE](LICENSE).
