# Disk helpers for the ISO installer. Sourced by kestrel-install.

# Path of partition N on a disk device. nvme/mmcblk/loop partitions carry a 'p'
# before the number; sd/vd/xd do not.
kestrel_part_path() {
  local disk="$1" n="$2"
  case "${disk##*/}" in
    nvme* | mmcblk* | loop* | md*) printf '%s\n' "${disk}p${n}" ;;
    *) printf '%s\n' "${disk}${n}" ;;
  esac
}

# Partition size constants for the Kestrel layout.
KESTREL_BIOS_SIZE="1MiB"
KESTREL_ESP_SIZE="2GiB"

# Wait for the kernel and udev to settle after a partition table change.
kestrel_settle_disk() {
  partprobe "$1" 2>/dev/null || true
  udevadm settle || true
}

# Wait (bounded, ~5s) for a partition node to appear, returning whether it did.
# Partition nodes can lag the table change on a slow or 4K-sector disk; a
# mkfs or mount against a missing node fails with a confusing superblock error.
kestrel_wait_block_device() {
  local dev="$1" i
  for ((i = 0; i < 50; i++)); do
    [[ -b $dev ]] && return 0
    udevadm settle --timeout=1 || true
    sleep 0.1
  done
  [[ -b $dev ]]
}

# Highest partition number currently in the disk's table (0 when empty).
kestrel_last_partition_number() {
  sgdisk -p "$1" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {n=$1} END {print n+0}'
}

# Create the Kestrel partition layout in the free space [start,end] (sgdisk
# sector arguments) of an existing table:
#   bios_grub (ef02), ESP (ef00, vfat, /boot), root (8309).
# Sets KESTREL_PART_BIOS/ESP/ROOT to the created partition numbers.
#   $1 disk   $2 start   $3 end (0 = end of disk)
kestrel_create_partitions() {
  local disk="$1" start="$2" end="$3"
  local base
  base=$(( $(kestrel_last_partition_number "$disk") + 1 ))

  KESTREL_PART_BIOS=$base
  KESTREL_PART_ESP=$((base + 1))
  KESTREL_PART_ROOT=$((base + 2))

  sgdisk -n "${KESTREL_PART_BIOS}:${start}:+${KESTREL_BIOS_SIZE}" \
    -t "${KESTREL_PART_BIOS}:ef02" -c "${KESTREL_PART_BIOS}:bios_grub" "$disk"
  sgdisk -n "${KESTREL_PART_ESP}:+0:+${KESTREL_ESP_SIZE}" \
    -t "${KESTREL_PART_ESP}:ef00" -c "${KESTREL_PART_ESP}:KESTREL-ESP" "$disk"
  sgdisk -n "${KESTREL_PART_ROOT}:0:${end}" \
    -t "${KESTREL_PART_ROOT}:8309" -c "${KESTREL_PART_ROOT}:KESTREL-ROOT" "$disk"

  kestrel_settle_disk "$disk"
}

# Largest contiguous free region on a GPT disk, as "start end" sectors, or
# return 1 if there is none. Uses the partition table plus `sgdisk -E`.
kestrel_largest_free_region() {
  local disk="$1"
  local used last
  used=$(sgdisk -p "$disk" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $2, $3}')
  last=$(sgdisk -E "$disk" 2>/dev/null) || return 1
  [[ -n $last ]] || return 1

  local best_start="" best_end="" best_len=0
  local cursor=2048 # first 1 MiB holds the GPT
  local s e
  while IFS=' ' read -r s e; do
    [[ -n $s ]] || continue
    if ((s - cursor > best_len)); then
      best_len=$((s - cursor))
      best_start=$cursor
      best_end=$((s - 1))
    fi
    ((e + 1 > cursor)) && cursor=$((e + 1))
  done <<<"$used"

  if ((last - cursor + 1 > best_len)); then
    best_len=$((last - cursor + 1))
    best_start=$cursor
    best_end=$last
  fi

  [[ -n $best_start && $best_len -gt 0 ]] || return 1
  printf '%s %s\n' "$best_start" "$best_end"
}
