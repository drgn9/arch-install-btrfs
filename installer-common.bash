# installer-common.bash - shared constants and helpers for the USB installer
# and the rescue reinstall path. Sourced, never executed.
# shellcheck shell=bash
# shellcheck disable=SC2034

BTRFS_MOUNT_OPTIONS="noatime,compress=zstd:3"
BTRFS_DATA_MOUNT_OPTIONS="$BTRFS_MOUNT_OPTIONS,nodev,nosuid"
BTRFS_STRICT_MOUNT_OPTIONS="$BTRFS_DATA_MOUNT_OPTIONS,noexec"
EFI_MOUNT_OPTIONS="fmask=0137,dmask=0027,nodev,nosuid,noexec"
BTRFS_SUBVOLUMES=(
    @
    @snapshots
    @home
    @root
    @var_log
    @var_cache
    @var_tmp
    @docker
    @containerd
    @containers
    @machines
    @portables
    @flatpak
    @libvirt
    @sbctl
    @iwd
    @tailscale
    @netbird
    @srv
)
BTRFS_SUBVOLUME_MOUNTS=(
    "@snapshots:/.snapshots"
    "@home:/home"
    "@root:/root"
    "@var_log:/var/log"
    "@var_cache:/var/cache"
    "@var_tmp:/var/tmp"
    "@docker:/var/lib/docker"
    "@containerd:/var/lib/containerd"
    "@containers:/var/lib/containers"
    "@machines:/var/lib/machines"
    "@portables:/var/lib/portables"
    "@flatpak:/var/lib/flatpak"
    "@libvirt:/var/lib/libvirt"
    "@sbctl:/var/lib/sbctl"
    "@iwd:/var/lib/iwd"
    "@tailscale:/var/lib/tailscale"
    "@netbird:/var/lib/netbird"
    "@srv:/srv"
)
# Rescue reinstall: these always survive; they are what make reinstall
# possible without Secure Boot Setup Mode or re-enrollment. @home is in
# neither fixed set because preserving it is a runtime choice.
BTRFS_PRESERVE_SUBVOLUMES=(
    @sbctl
    @iwd
    @tailscale
    @netbird
)
# Rescue reinstall: these are replaced. @ is renamed aside and retained
# until the reinstall succeeds; the others are deleted and recreated.
BTRFS_RECREATE_SUBVOLUMES=(
    @
    @snapshots
    @root
    @var_log
    @var_cache
    @var_tmp
    @docker
    @containerd
    @containers
    @machines
    @portables
    @flatpak
    @libvirt
    @srv
)

have_network() {
    if command -v curl &>/dev/null; then
        curl --silent --max-time 5 https://archlinux.org >/dev/null 2>&1
    else
        ping -c 1 -W 5 archlinux.org &>/dev/null
    fi
}

partition_path() {
    local disk=$1
    local number=$2

    if [[ "$disk" =~ [0-9]$ ]]; then
        printf '%sp%s\n' "$disk" "$number"
    else
        printf '%s%s\n' "$disk" "$number"
    fi
}

detect_microcode() {
    cpu_vendor=$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')
    if [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
        microcode="amd-ucode"
    else
        microcode="intel-ucode"
    fi
}

detect_gpu_package_files() {
    local gpu_info

    gpu_info=$(lspci | grep -E "VGA|3D" || true)
    gpu_package_files=()
    gpu_label="none"

    if grep -qi intel <<<"$gpu_info"; then
        gpu_package_files+=(packages/desktop-driver-intel.conf)
        gpu_label="Intel"
    fi

    if grep -qi amd <<<"$gpu_info"; then
        gpu_package_files+=(packages/desktop-driver-amd.conf)
        if [[ "$gpu_label" == "Intel" ]]; then
            gpu_label="Intel + AMD"
        else
            gpu_label="AMD"
        fi
    fi
}

target_chroot() {
    arch-chroot /mnt "$@"
}

copy_settings_file() {
    local subsystem=$1
    local target=$2
    local mode=${3:-0644}

    copy_settings_source "$subsystem/${target#/}" "$target" "$mode"
}

copy_settings_source() {
    local source=$1
    local target=$2
    local mode=${3:-0644}

    install -D -m "$mode" "$SETTINGS_DIR/$source" "/mnt$target"
}

append_settings_file() {
    local subsystem=$1
    local target=$2

    install -d -m 0755 "$(dirname "/mnt$target")"
    touch "/mnt$target"
    append_unique_lines "$SETTINGS_DIR/$subsystem/${target#/}" "$target"
}

enable_target_service() {
    local output

    if ! output=$(systemctl --root=/mnt enable "$1" 2>&1); then
        show_error "Failed to enable $1: $output"
        return 1
    fi
}

mask_target_unit() {
    systemctl --root=/mnt mask "$1" &>/dev/null || true
}

write_target_file() {
    local path=$1
    local mode=$2
    local tmp

    tmp=$(mktemp)
    cat >"$tmp"
    install -D -m "$mode" "$tmp" "/mnt$path"
    rm -f "$tmp"
}

append_unique_lines() {
    local source=$1
    local target=$2

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        grep -qxF "$line" "/mnt$target" || printf '%s\n' "$line" >>"/mnt$target"
    done <"$source"
}

collect_selected_packages() {
    local file

    selected_package_files=(packages/base.conf packages/desktop-base.conf packages/desktop-niri.conf)
    selected_package_files+=("${gpu_package_files[@]}")

    for file in "${selected_package_files[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$file" ]]; then
            show_error "Missing package file: $SCRIPT_DIR/$file"
            exit 1
        fi
    done

    mapfile -t selected_packages < <(awk 'NF && $1 !~ /^#/ { print $1 }' "${selected_package_files[@]/#/$SCRIPT_DIR/}" | sort -u)
    if (( ${#selected_packages[@]} == 0 )); then
        show_error "No packages found in: ${selected_package_files[*]}"
        exit 1
    fi
}

preflight_validate_packages() {
    local packages=("${selected_packages[@]}" snap-pac)

    show_info "Validating ${#packages[@]} package names from: ${selected_package_files[*]} plus deferred snap-pac"
    if ! pacman -Sp --print-format '%n' "${packages[@]}" >/dev/null; then
        show_error "Unresolvable package names found. Fix the package files and re-run."
        exit 1
    fi
}

btrfs_mount_options_for() {
    local mountpoint=$1

    case "$mountpoint" in
        /.snapshots|/var/log|/var/cache|/var/lib/sbctl|/var/lib/iwd|/var/lib/tailscale|/var/lib/netbird)
            printf '%s\n' "$BTRFS_STRICT_MOUNT_OPTIONS"
            ;;
        /home|/root|/var/tmp|/srv)
            printf '%s\n' "$BTRFS_DATA_MOUNT_OPTIONS"
            ;;
        *)
            printf '%s\n' "$BTRFS_MOUNT_OPTIONS"
            ;;
    esac
}

delete_boot_entries_by_label() {
    local label=$1
    local boot_num

    while read -r boot_num; do
        [[ -n "$boot_num" ]] || continue
        target_chroot efibootmgr --bootnum "$boot_num" --delete-bootnum --unicode || true
    done < <(target_chroot efibootmgr --unicode 2>/dev/null | awk -v label="$label" '
        {
            token = $1
            if (token !~ /^Boot[0-9A-Fa-f]{4}\*?$/) next
            line = $0
            sub(/^Boot[0-9A-Fa-f]{4}\*?[ \t]+/, "", line)
            sub(/\t.*$/, "", line)
            if (line == label) { sub(/^Boot/, "", token); sub(/\*.*/, "", token); print token }
        }')
}

manage_efi_boot_entries() {
    local entries entry boot_num

    show_section "EFI Boot Entries"
    efibootmgr --unicode || true

    while true; do
        entries=$(efibootmgr --unicode 2>/dev/null | awk '$1 ~ /^Boot[0-9A-Fa-f]{4}\*?$/ { print }' || true)

        if [[ -z "$entries" ]]; then
            show_info "No EFI boot entries found"
            break
        fi

        entry=$(printf 'Skip\n%s\n' "$entries" | gum choose --header "Select EFI boot entry to delete, or Skip:")

        if [[ "$entry" == "Skip" ]]; then
            break
        fi

        boot_num=$(awk '{ token = $1; if (token ~ /^Boot[0-9A-Fa-f]{4}\*?$/) { sub(/^Boot/, "", token); sub(/\*$/, "", token); print token } }' <<<"$entry")

        if [[ -n "$boot_num" ]] && gum confirm "Delete EFI boot entry Boot$boot_num?"; then
            efibootmgr --bootnum "$boot_num" --delete-bootnum --unicode
            show_info "Deleted EFI boot entry Boot$boot_num"
        fi
    done
}
