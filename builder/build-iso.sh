#!/bin/bash

set -e

# Note that these are packages installed to the Arch container used to build the ISO.
pacman-key --init
# Full upgrade, not just a sync: the container image can lag the mirrors, and
# mixing a partial upgrade breaks the Python toolchain the source-package
# builds rely on (glibc/libm skew).
pacman --noconfirm -Syu --needed archlinux-keyring archiso git sudo base-devel jq grub

# AUR packages pull multilib dependencies (lib32-zlib, lib32-libglvnd, ...);
# the base container ships multilib commented out, so enable it.
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>/etc/pacman.conf
  pacman --noconfirm -Sy >/dev/null
fi

# Setup build locations. There is no offline package mirror: the live rootfs is
# a fully installed-shaped Kestrel system and the installer copies it to disk.
build_cache_dir="${KESTREL_BUILD_CACHE:-/var/cache}"
mkdir -p "$build_cache_dir/"

# Heavy scratch (kernel/AUR source trees, mkarchiso work) is mounted from the
# host (see iso-make) so it lands on /data rather than the container overlay.
build_work_dir="${KESTREL_BUILD_WORK:-/tmp}"
mkdir -p "$build_work_dir"

# We base our ISO on the official arch ISO (releng) config
cp -r /archiso/configs/releng/* "$build_cache_dir/"
rm "$build_cache_dir/airootfs/etc/motd"

# The vendored archiso releng list can name packages Arch has since dropped
# (broadcom-wl, for one). Keep only what the repositories still provide.
pacman --noconfirm -Sy >/dev/null
mapfile -t releng_pkgs <"$build_cache_dir/packages.x86_64"
: >"$build_cache_dir/packages.x86_64"
for pkg in "${releng_pkgs[@]}"; do
  # The Kestrel kernel replaces Arch's. With both installed, the staged
  # /boot/vmlinuz-linux (and therefore the ISO) ends up being the unpatched one.
  [[ $pkg == linux ]] && continue
  if pacman -Si "$pkg" >/dev/null 2>&1; then
    printf '%s\n' "$pkg" >>"$build_cache_dir/packages.x86_64"
  else
    echo "Dropping unavailable live-env package: $pkg" >&2
  fi
done

# Avoid using reflector for mirror identification as we are relying on the global CDN
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Bring in our configs (includes the build pacman.conf and the live/target copy).
cp -r /configs/* "$build_cache_dir/"

# Setup Kestrel itself, at the installed-system path the live session and the
# installer both read.
mkdir -p "$build_cache_dir/airootfs/usr/share"
if [[ -d /kestrel ]]; then
  # The cache persists across builds. Without removing the old payload first,
  # `cp -r /kestrel <existing dir>` nests it as kestrel/kestrel and silently
  # keeps the previous build's config.
  rm -rf "$build_cache_dir/airootfs/usr/share/kestrel"
  cp -rp /kestrel "$build_cache_dir/airootfs/usr/share/kestrel"
else
  # Same cache as the local-source branch: leaving the previous payload in
  # place makes git clone fail on a non-empty directory.
  rm -rf "$build_cache_dir/airootfs/usr/share/kestrel"
  git clone -b "$KESTREL_INSTALLER_REF" "https://github.com/$KESTREL_INSTALLER_REPO.git" \
    "$build_cache_dir/airootfs/usr/share/kestrel"
fi
rm -rf "$build_cache_dir/airootfs/usr/share/kestrel/.git"

# Download and verify the Node.js binary for the offline install.
NODE_DIST_URL="https://nodejs.org/dist/latest"
NODE_SHASUMS=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
NODE_FILENAME=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $2}')
NODE_SHA=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $1}')
curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "$build_work_dir/$NODE_FILENAME"
echo "$NODE_SHA $build_work_dir/$NODE_FILENAME" | sha256sum -c - || {
  echo "ERROR: Node.js checksum verification failed!"
  exit 1
}
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "$build_work_dir/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"

# Live environment packages: releng set plus the full Kestrel desktop, so the
# ISO boots to a graphical Hyprland + Quickshell session and the copied rootfs
# is a complete installed system.
arch_packages=(git gum jq openssl plymouth stress-ng rt-tests perf powertop sysstat)
mapfile -t kestrel_desktop < <(grep -hvE '^[[:space:]]*(#|$)' \
  "$build_cache_dir/airootfs/usr/share/kestrel/install/kestrel-base.packages" \
  "$build_cache_dir/airootfs/usr/share/kestrel/install/kestrel-other.packages")
printf '%s\n' "${arch_packages[@]}" "${kestrel_desktop[@]}" >>"$build_cache_dir/packages.x86_64"

# Build the AUR packages the live rootfs needs into a local build-time repo.
# AUR packages can depend on other AUR packages, so build `yay` first and let it
# resolve the rest of the closure. The repo is used only to install these
# packages into the live rootfs; it is not shipped on the ISO.
aur_pkg_list="$build_cache_dir/airootfs/usr/share/kestrel/install/kestrel-aur.packages"
aur_repo="$build_work_dir/aur-repo"
if [[ -f "$aur_pkg_list" ]] && grep -qvE '^[[:space:]]*(#|$)' "$aur_pkg_list"; then
  # The AUR list is the union of what Kestrel may need per machine. Two entries
  # cannot be baked into the live rootfs baseline:
  #   * the pre-Turing NVIDIA 580xx driver hard-conflicts with the modern
  #     nvidia-open stack the desktop set already ships; hardware detection picks
  #     the right driver at install.
  #   * yay resolves `vi` to the repository's ex-vi-compat provider, so it never
  #     lands as an AUR package; the rootfs ships vim instead.
  aur_skip=(nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils vi)
  aur_build=()
  while IFS= read -r entry; do
    [[ -z $entry ]] && continue
    name="${entry%%=*}"
    for skip in "${aur_skip[@]}"; do
      [[ $name == "$skip" ]] && continue 2
    done
    aur_build+=("$name")
  done < <(grep -vE '^[[:space:]]*(#|$)' "$aur_pkg_list")

  # Persistent across runs when the host cache dir is mounted (see iso-make).
  aur_pkgdest="${KESTREL_AUR_CACHE:-$build_work_dir/aur-packages}"
  mkdir -p "$aur_pkgdest" "$aur_repo"

  # yay resolves the whole AUR closure (AUR packages depend on each other), so a
  # complete cache lets us skip building entirely on a repeat run.
  cache_complete=1
  for name in "${aur_build[@]}"; do
    if ! find "$aur_pkgdest" -maxdepth 1 -name "$name-*.pkg.tar.zst" -print -quit | grep -q .; then
      cache_complete=0
      break
    fi
  done

  if ((cache_complete)); then
    echo "All AUR packages found in cache; skipping AUR build"
    cp "$aur_pkgdest"/*.pkg.tar.zst "$aur_repo/"
  else
    useradd -m builduser
    echo "builduser ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers
    echo "Defaults:builduser !syslog" >>/etc/sudoers

    aur_build_dir="$build_work_dir/aur-build"
    mkdir -p "$aur_build_dir"
    chown builduser:builduser "$aur_build_dir" "$aur_pkgdest"

    # yay first, so it can resolve AUR dependencies for everything else.
    su - builduser -c "rm -rf '$aur_build_dir/yay' && git clone --depth 1 https://aur.archlinux.org/yay.git '$aur_build_dir/yay' && cd '$aur_build_dir/yay' && PKGDEST='$aur_pkgdest' makepkg -s -f --noconfirm --nocheck"
    pacman -U --noconfirm "$aur_pkgdest"/yay-*.pkg.tar.zst

    # Some AUR PKGBUILDs need a library only at build time that they declare as a
    # runtime dependency (makepkg -s installs makedepends, not depends), so yay
    # alone misses it. gtk4 is the one that bites the share picker today.
    pacman -S --noconfirm --needed gtk4 libadwaita >/dev/null

    yay_targets=()
    for name in "${aur_build[@]}"; do
      [[ $name == yay ]] && continue
      yay_targets+=("$name")
    done
    echo "Installing AUR closure: ${yay_targets[*]}"
    su - builduser -c "PKGDEST='$aur_pkgdest' yay -S --noconfirm --needed --answerclean None --answerdiff None --removemake --mflags '--nocheck' ${yay_targets[*]}"

    pkill -u builduser 2>/dev/null || true
    userdel -r builduser 2>/dev/null || true

    # Publish every built package into the build-time repo mkarchiso installs from.
    cp "$aur_pkgdest"/*.pkg.tar.zst "$aur_repo/"
  fi

  repo-add --new "$aur_repo/aur.db.tar.gz" "$aur_repo/"*.pkg.tar.zst

  # Install into the live rootfs only the AUR packages we actually have a built
  # package for, so a name yay resolved to a repo provider never reaches pacstrap.
  for name in "${aur_build[@]}"; do
    compgen -G "$aur_repo/$name-*.pkg.tar.zst" >/dev/null || continue
    printf '%s\n' "$name" >>"$build_cache_dir/packages.x86_64"
  done

  printf '\n[aur]\nSigLevel = Optional TrustAll\nServer = file://%s/\n' "$aur_repo" \
    >>"$build_cache_dir/pacman.conf"
fi

# Build packages Kestrel ships from source (a git repository rather than the
# AUR) into the same build-time repo. Format: name=git-url. The recipe is the
# repository's local PKGBUILD, which builds the checked-out tree itself.
source_pkg_list="$build_cache_dir/airootfs/usr/share/kestrel/install/kestrel-source.packages"
if [[ -f "$source_pkg_list" ]] && grep -qvE '^[[:space:]]*(#|$)' "$source_pkg_list"; then
  useradd -m builduser 2>/dev/null || true
  echo "builduser ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers
  echo "Defaults:builduser !syslog" >>/etc/sudoers
  mkdir -p "$aur_repo"
  chown builduser:builduser "$aur_repo"

  while IFS= read -r entry; do
    [[ -z $entry ]] && continue
    name="${entry%%=*}"
    rest="${entry#*=}"
    url="${rest%%#*}"
    sub=""
    [[ "$rest" == *\#* ]] && sub="${rest#*#}"
    # Reuse a package built from the same upstream commit. The package version
    # does not change per commit (the kernel's pkgver is _major._minor), so the
    # commit is recorded in a marker next to the package.
    rev=$(git ls-remote "$url" HEAD 2>/dev/null | cut -f1) || true
    marker="$aur_repo/$name.rev"
    if [[ ${KESTREL_REBUILD_SOURCE:-0} != 1 && -n $rev ]] \
      && compgen -G "$aur_repo/$name-[0-9]*.pkg.tar.zst" >/dev/null \
      && [[ -f $marker && $(<"$marker") == "$rev" ]]; then
      echo "Using cached source package: $name ($rev)"
      printf '%s\n' "$name" >>"$build_cache_dir/packages.x86_64"
      compgen -G "$aur_repo/$name-headers-*.pkg.tar.zst" >/dev/null &&
        printf '%s\n' "$name-headers" >>"$build_cache_dir/packages.x86_64"
      continue
    fi
    echo "Building source package: $name from $url${sub:+ ($sub)}"
    src_dir="$build_work_dir/src/$name"
    rm -rf "$src_dir"
    git clone --quiet "$url" "$src_dir"
    pkgbuild_dir="$src_dir/packaging/local"
    [[ -d $pkgbuild_dir ]] || pkgbuild_dir="$src_dir"
    [[ -n "$sub" ]] && pkgbuild_dir="$src_dir/$sub"
    chown -R builduser:builduser "$src_dir"
    su - builduser -c "cd '$pkgbuild_dir' && PKGDEST='$aur_repo' makepkg -s -f --noconfirm --nocheck"
    printf '%s\n' "$rev" >"$marker"
    rm -rf "$src_dir"
    printf '%s\n' "$name" >>"$build_cache_dir/packages.x86_64"
    # Kernels ship a -headers package that DKMS (NVIDIA, etc.) needs to rebuild
    # against. Install it when the build produced one.
    compgen -G "$aur_repo/$name-headers-*.pkg.tar.zst" >/dev/null &&
      printf '%s\n' "$name-headers" >>"$build_cache_dir/packages.x86_64"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$source_pkg_list")

  pkill -u builduser 2>/dev/null || true
  userdel -r builduser 2>/dev/null || true

  repo-add "$aur_repo/aur.db.tar.gz" "$aur_repo/"*.pkg.tar.zst

  if ! grep -q '^\[aur\]' "$build_cache_dir/pacman.conf"; then
    printf '\n[aur]\nSigLevel = Optional TrustAll\nServer = file://%s/\n' "$aur_repo" \
      >>"$build_cache_dir/pacman.conf"
  fi
fi

# Benchmark harness from the local kernel checkout. kestrel-bench prefers this
# path over cloning, so the ISO works offline and carries the same bench code
# as the kernel repository being tested.
if [[ -d ${KERNEL_PATH:-/kernel}/bench ]]; then
  rm -rf "$build_cache_dir/airootfs/usr/share/kestrel-bench"
  install -d "$build_cache_dir/airootfs/usr/share/kestrel-bench"
  cp -a "${KERNEL_PATH:-/kernel}/bench" "$build_cache_dir/airootfs/usr/share/kestrel-bench/bench"
  chmod +x "$build_cache_dir"/airootfs/usr/share/kestrel-bench/bench/*
fi

# schbench is not in the Arch repos and the live bench script expects it.
if [[ ! -x "$build_cache_dir/airootfs/usr/local/bin/schbench" ]]; then
  rm -rf "$build_work_dir/schbench"
  if git clone --depth 1 https://github.com/masoncl/schbench "$build_work_dir/schbench" >/dev/null 2>&1; then
    if make -C "$build_work_dir/schbench" >/dev/null 2>&1; then
      install -Dm755 "$build_work_dir/schbench/schbench" "$build_cache_dir/airootfs/usr/local/bin/schbench" || true
    fi
  fi
fi

# Live-only packages: everything the releng live set adds on top of the
# installed Kestrel system. The installer removes these from the target (A3).
# Leaf packages the installed system still wants that only releng provides are
# listed as essentials; anything required by a kept package is protected at
# install time anyway.
installed_essentials=(mkinitcpio sudo openssh cryptsetup pciutils usbutils man-pages vim nano)
keep_list=$(
  grep -hvE '^[[:space:]]*(#|$)' \
    "$build_cache_dir/airootfs/usr/share/kestrel/install/kestrel-base.packages" \
    "$build_cache_dir/airootfs/usr/share/kestrel/install/kestrel-other.packages" |
    sed -E 's/=.*$//'
  printf '%s\n' "${arch_packages[@]}" "${installed_essentials[@]}"
)
live_only_file="$build_cache_dir/airootfs/usr/share/kestrel/install/kestrel-live-only.packages"
{
  echo "# Generated by build-iso.sh: releng/live-only packages the installer"
  echo "# removes from the target. Do not edit by hand."
  for pkg in "${releng_pkgs[@]}"; do
    [[ -n $pkg ]] || continue
    grep -qxF "$pkg" <<<"$keep_list" && continue
    printf '%s\n' "$pkg"
  done
} >"$live_only_file"

# Finally, we assemble the entire ISO. archiso's work dir persists in the
# mounted cache and its per-step "run once" markers make a second run skip
# every step, so a rebuild would silently reuse the previous ISO.
rm -rf "$build_cache_dir/work/"
mkarchiso -v -w "$build_cache_dir/work/" -o "/out/" "$build_cache_dir/"

# Fix ownership of output and scratch files to match host user
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
  chown -R "$HOST_UID:$HOST_GID" /out/
  [ -d /build ] && chown -R "$HOST_UID:$HOST_GID" /build
fi
