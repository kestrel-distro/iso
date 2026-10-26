#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="kestrel"
iso_label="kestrel_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Kestrel <https://github.com/kestrel-distro/kestrel>"
iso_application="Kestrel Installer"
# Include the time, so rebuilding on the same day does not overwrite the
# previous ISO (mkarchiso builds the filename as $iso_name-$iso_version-$arch.iso).
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d-%H%M)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.grub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
# zstd compresses in parallel and decompresses far faster than xz, which matters
# for a live session booted from the ISO.
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15' '-b' '1M' '-processors' "$(nproc)")
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.gnupg"]="0:0:700"
  ["/root/configurator"]="0:0:755"
  ["/usr/local/bin/kestrel-install"]="0:0:755"
  ["/usr/local/bin/kestrel-live-notice"]="0:0:755"
  ["/usr/local/bin/kestrel-vm-report"]="0:0:755"
  ["/usr/local/lib/kestrel-live-init"]="0:0:755"
  ["/usr/local/lib/kestrel-target-setup"]="0:0:755"
  ["/usr/local/lib/kestrel-host-logs"]="0:0:755"
  ["/usr/local/share/kestrel-live"]="0:0:755"
)
