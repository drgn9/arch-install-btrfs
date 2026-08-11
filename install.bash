#!/usr/bin/env bash

clear
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_DIR="$SCRIPT_DIR/settings"
RESCUE_UKI_SOURCE="$SCRIPT_DIR/artifacts/arch-rescue.efi"
RESCUE_UKI_TARGET=/efi/EFI/Linux/arch-rescue.efi
BTRFS_MOUNT_OPTIONS="noatime,compress=zstd:3"
BTRFS_DATA_MOUNT_OPTIONS="$BTRFS_MOUNT_OPTIONS,nodev,nosuid"
BTRFS_STRICT_MOUNT_OPTIONS="$BTRFS_DATA_MOUNT_OPTIONS,noexec"
EFI_MOUNT_OPTIONS="fmask=0137,dmask=0027,nodev,nosuid,noexec"
MINIMUM_DISK_BYTES=$((32 * 1024 * 1024 * 1024))
target_mounted=no
cryptroot_opened=no
cleanup_running=no
failure_line=
failure_command=
failure_status=
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

if [[ ${EUID:-0} -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo "ERROR: This installer requires UEFI boot mode. Legacy BIOS is not supported." >&2
    exit 1
fi

have_network() {
    if command -v curl &>/dev/null; then
        curl --silent --max-time 5 https://archlinux.org >/dev/null 2>&1
    else
        ping -c 1 -W 5 archlinux.org &>/dev/null
    fi
}

connect_wifi_tui() {
    local attempt

    if ! command -v impala &>/dev/null; then
        echo "impala is not available. Connect manually, then choose re-check." >&2
        return 1
    fi

    rfkill unblock wifi 2>/dev/null || true
    systemctl start iwd.service 2>/dev/null || true

    impala || return 1

    echo "Waiting for internet access..."
    for ((attempt = 0; attempt < 15; attempt++)); do
        if have_network; then
            return 0
        fi
        sleep 2
    done
    echo "impala exited, but internet access was not detected yet." >&2
    return 1
}

ensure_network() {
    local choice

    if have_network; then
        echo "Internet connection OK"
        return 0
    fi

    while ! have_network; do
        echo ""
        echo "No internet connection detected. The installer needs internet to download packages."
        echo "  1) Open Wi-Fi manager (impala)"
        echo "  2) Re-check (choose this after plugging in an ethernet cable)"
        echo "  3) Abort"
        read -rp "Choice [1]: " choice
        case "${choice:-1}" in
            1) connect_wifi_tui || echo "Wi-Fi setup did not succeed. Try again." >&2 ;;
            2) ;;
            3) exit 1 ;;
            *) echo "Enter 1, 2 or 3." >&2 ;;
        esac
    done
    echo "Internet connection OK"
}

ensure_network

if timedatectl set-ntp true &>/dev/null; then
    echo "NTP synchronization enabled"
else
    echo "WARNING: Could not enable NTP with timedatectl; continuing. Fix the clock manually if pacman reports signature errors." >&2
fi

sed -Ei 's/^#?(ParallelDownloads).*/\1 = 10/' /etc/pacman.conf
echo "Refreshing pacman databases and archlinux-keyring"
pacman -Sy --needed --noconfirm archlinux-keyring

deps_needed=()
for dep in gum impala cryptsetup efibootmgr sfdisk wipefs blkdiscard partprobe mkfs.fat mkfs.btrfs btrfs lspci pacstrap arch-chroot genfstab; do
    command -v "$dep" &>/dev/null || deps_needed+=("$dep")
done

if [[ ${#deps_needed[@]} -gt 0 ]]; then
    echo "Installing live environment dependencies: ${deps_needed[*]}"
    pacman -S --needed --noconfirm gum impala cryptsetup efibootmgr util-linux dosfstools btrfs-progs parted pciutils arch-install-scripts
fi

UI_ACCENT=212
UI_ACTION=214
UI_SUCCESS=82
UI_WIDTH=74

show_header() {
    clear
    gum style \
        --foreground "$UI_ACCENT" --border-foreground "$UI_ACCENT" --border double \
        --align center --width "$UI_WIDTH" --margin "1 2" --padding "1 2" \
        "Arch New Installer" \
        "" \
        "Niri-only Btrfs + UKI + systemd-boot"
}

show_section() {
    gum style \
        --foreground "$UI_ACCENT" --border-foreground "$UI_ACCENT" --border rounded \
        --bold --width "$UI_WIDTH" --margin "1 2" --padding "0 2" \
        "$1"
}

show_action() {
    local title=$1
    shift

    gum style \
        --foreground "$UI_ACTION" --border-foreground "$UI_ACTION" --border double \
        --bold --width "$UI_WIDTH" --margin "1 2" --padding "1 2" \
        "$title" "" "$@"
}

show_success() {
    gum style --foreground "$UI_SUCCESS" --bold --margin "1 2" "$1"
}

show_info() {
    gum log --level info "$1"
}

show_warn() {
    gum log --level warn "$1"
}

show_error() {
    gum log --level error "$1"
}

if findmnt -rn -M /mnt >/dev/null 2>&1; then
    show_error "/mnt is already mounted. Unmount it before running the installer."
    exit 1
fi

if [[ -e /dev/mapper/cryptroot ]]; then
    show_error "An installer mapper already exists. Close cryptroot before running."
    exit 1
fi

record_failure() {
    failure_line=$1
    failure_command=$2
    failure_status=$3
}

handle_signal() {
    failure_line=$1
    failure_command=$2
    failure_status=130
    exit 130
}

cleanup_on_exit() {
    local status=$?
    local cleanup_failed=no
    local mapper_device mount_source

    [[ "$cleanup_running" == no ]] || return
    cleanup_running=yes
    trap - ERR EXIT
    trap '' HUP INT TERM

    if (( status != 0 )); then
        if [[ -n "$failure_line" ]]; then
            show_error "Installation failed at line $failure_line (exit ${failure_status:-$status}): $failure_command"
        else
            show_error "Installation failed (exit $status)"
        fi
    fi

    if [[ "$target_mounted" != no ]]; then
        if ! findmnt -rn -M /mnt >/dev/null 2>&1; then
            target_mounted=no
        else
            mount_source=$(readlink -f -- "$(findmnt -v -rn -M /mnt -o SOURCE)")
            if [[ -z "${root_device:-}" || "$mount_source" != "$(readlink -f -- "$root_device")" ]]; then
                show_error "Refusing to unmount /mnt because its source is not the installer root device"
                cleanup_failed=yes
            elif umount -R /mnt 2>/dev/null; then
                target_mounted=no
            else
                show_error "Failed to unmount installer-owned filesystems under /mnt"
                cleanup_failed=yes
            fi
        fi
    fi

    if [[ "$cryptroot_opened" != no ]]; then
        if [[ ! -e /dev/mapper/cryptroot ]]; then
            cryptroot_opened=no
        else
            mapper_device=$(cryptsetup status cryptroot 2>/dev/null | awk '$1 == "device:" { print $2 }')
            if [[ -z "${root_part:-}" || "$(readlink -f -- "$mapper_device")" != "$(readlink -f -- "$root_part")" ]]; then
                show_error "Refusing to close cryptroot because it is not backed by the installer root partition"
                cleanup_failed=yes
            elif cryptsetup close cryptroot 2>/dev/null; then
                cryptroot_opened=no
            else
                show_error "Failed to close installer-owned mapper cryptroot"
                cleanup_failed=yes
            fi
        fi
    fi

    if [[ "$cleanup_failed" == yes && $status -eq 0 ]]; then
        status=1
    fi
    exit "$status"
}

trap 'record_failure "$LINENO" "$BASH_COMMAND" "$?"' ERR
trap 'handle_signal "$LINENO" "hangup"' HUP
trap 'handle_signal "$LINENO" "interrupted"' INT TERM
trap cleanup_on_exit EXIT

device_has_mounts() {
    lsblk --noheadings --output MOUNTPOINTS "$1" | grep -q '[^[:space:]]'
}

device_has_swap() {
    local node swap

    while read -r node; do
        [[ -n "$node" ]] || continue
        while read -r swap; do
            [[ -n "$swap" ]] || continue
            if [[ "$(readlink -f -- "$swap")" == "$(readlink -f -- "$node")" ]]; then
                return 0
            fi
        done < <(swapon --noheadings --raw --show=NAME 2>/dev/null)
    done < <(lsblk --noheadings --raw --paths --output NAME "$1")

    return 1
}

device_has_holders() {
    local kname type
    local -a holders

    while read -r kname type; do
        [[ "$type" == disk || "$type" == part ]] || continue
        shopt -s nullglob
        holders=("/sys/class/block/$kname/holders/"*)
        shopt -u nullglob
        (( ${#holders[@]} == 0 )) || return 0
    done < <(lsblk --noheadings --raw --output KNAME,TYPE "$1")

    return 1
}

validate_disk_target() {
    local device_path=$1
    local device_type

    if [[ ! -b "$device_path" ]]; then
        show_error "$device_path is not a block device"
        return 1
    fi

    device_type=$(lsblk --noheadings --output TYPE "$device_path" | head -n 1 | tr -d '[:space:]')
    if [[ "$device_type" != "disk" ]]; then
        show_error "$device_path is not a disk"
        return 1
    fi

    if device_has_mounts "$device_path"; then
        show_error "$device_path or one of its partitions is mounted"
        return 1
    fi

    if device_has_swap "$device_path"; then
        show_error "$device_path or one of its partitions is active swap"
        return 1
    fi

    if device_has_holders "$device_path"; then
        show_error "$device_path or one of its partitions has an active block-device holder"
        return 1
    fi
}

capture_target_identity() {
    local canonical link

    canonical=$(readlink -f -- "$target_disk")
    target_disk_size=$(blockdev --getsize64 "$canonical")
    target_disk_serial=$(lsblk --noheadings --nodeps --output SERIAL "$canonical" | xargs)
    target_disk_wwn=$(lsblk --noheadings --nodeps --output WWN "$canonical" | xargs)
    target_disk_by_id=

    for link in /dev/disk/by-id/*; do
        [[ -L "$link" && "$link" != *-part[0-9]* ]] || continue
        if [[ "$(readlink -f -- "$link")" == "$canonical" ]]; then
            target_disk_by_id=$link
            break
        fi
    done

    if [[ -z "$target_disk_by_id" && -z "$target_disk_serial" && -z "$target_disk_wwn" ]]; then
        show_warn "No persistent by-id, serial, or WWN is available for $target_disk; device-path revalidation is the only identity check."
    fi
}

revalidate_target_identity() {
    local reference canonical current_size current_serial current_wwn

    reference=${target_disk_by_id:-$target_disk}
    canonical=$(readlink -f -- "$reference")
    [[ -b "$canonical" ]] || { show_error "Selected disk identity is no longer present: $reference"; return 1; }
    validate_disk_target "$canonical"

    current_size=$(blockdev --getsize64 "$canonical")
    current_serial=$(lsblk --noheadings --nodeps --output SERIAL "$canonical" | xargs)
    current_wwn=$(lsblk --noheadings --nodeps --output WWN "$canonical" | xargs)

    [[ "$current_size" == "$target_disk_size" ]] || { show_error "Selected disk size changed before destruction"; return 1; }
    [[ -z "$target_disk_serial" || "$current_serial" == "$target_disk_serial" ]] || { show_error "Selected disk serial changed before destruction"; return 1; }
    [[ -z "$target_disk_wwn" || "$current_wwn" == "$target_disk_wwn" ]] || { show_error "Selected disk WWN changed before destruction"; return 1; }

    if findmnt -rn -M /mnt >/dev/null 2>&1 || [[ -e /dev/mapper/cryptroot ]]; then
        show_error "Installer mount or mapper resources appeared before disk destruction"
        return 1
    fi

    target_disk=$canonical
}

verify_partition_layout() {
    local disk_kname efi_parent root_parent efi_number root_number efi_type root_type efi_size

    [[ -b "$efi_part" && -b "$root_part" ]] || { show_error "Expected target partitions were not created"; return 1; }

    disk_kname=$(lsblk --noheadings --nodeps --output KNAME "$target_disk" | xargs)
    efi_parent=$(lsblk --noheadings --nodeps --output PKNAME "$efi_part" | xargs)
    root_parent=$(lsblk --noheadings --nodeps --output PKNAME "$root_part" | xargs)
    efi_number=$(lsblk --noheadings --nodeps --output PARTN "$efi_part" | xargs)
    root_number=$(lsblk --noheadings --nodeps --output PARTN "$root_part" | xargs)
    efi_type=$(lsblk --noheadings --nodeps --output PARTTYPE "$efi_part" | xargs)
    root_type=$(lsblk --noheadings --nodeps --output PARTTYPE "$root_part" | xargs)
    efi_size=$(blockdev --getsize64 "$efi_part")

    [[ "$efi_parent" == "$disk_kname" && "$root_parent" == "$disk_kname" ]] || { show_error "Created partitions do not belong to $target_disk"; return 1; }
    [[ "$efi_number" == 1 && "$root_number" == 2 ]] || { show_error "Created partition numbers are not 1 and 2"; return 1; }
    [[ "${efi_type,,}" == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] || { show_error "Partition 1 is not an EFI System Partition"; return 1; }
    [[ "${root_type,,}" == 0fc63daf-8483-4772-8e79-3d69d8477de4 ]] || { show_error "Partition 2 is not a Linux filesystem partition"; return 1; }
    (( efi_size == 2 * 1024 * 1024 * 1024 )) || { show_error "EFI partition is not exactly 2 GiB"; return 1; }
}

verify_target_efi_signature() {
    local file=$1 verification

    verification=$(target_chroot sbctl --json verify "$file")
    target_chroot jq -e 'length == 1 and .[0].is_signed == 1' <<<"$verification" >/dev/null
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

preflight_validate_rescue_uki() {
    if [[ ! -f "$RESCUE_UKI_SOURCE" ]]; then
        show_error "Missing rescue UKI artifact: $RESCUE_UKI_SOURCE"
        show_error "Build the installer ISO with ./iso/build.sh so artifacts/arch-rescue.efi is included."
        exit 1
    fi
}

install_selected_packages() {
    show_info "Installing ${#selected_packages[@]} packages into the target"
    target_chroot pacman -S --needed --noconfirm "${selected_packages[@]}"
}

setup_snapper_rollback() {
    show_info "Configuring Snapper rollback"

    umount /mnt/.snapshots
    rmdir /mnt/.snapshots
    target_chroot snapper --no-dbus -c root create-config /
    target_chroot btrfs subvolume delete /.snapshots

    install -d -m 0750 /mnt/.snapshots
    mount -o "$(btrfs_mount_options_for /.snapshots),subvol=@snapshots" "$root_device" /mnt/.snapshots
    chmod 0750 /mnt/.snapshots

    target_chroot snapper --no-dbus -c root set-config \
        TIMELINE_CREATE=no \
        TIMELINE_CLEANUP=no \
        NUMBER_CLEANUP=no \
        EMPTY_PRE_POST_CLEANUP=no
    systemctl --root=/mnt disable snapper-timeline.timer
    target_chroot snapper --no-dbus -c root get-config >/dev/null

    copy_settings_file rollback /usr/local/sbin/rollback-root 0755

    # Install snap-pac only after Snapper's root config and sibling
    # @snapshots mount are in place, so installer pacman work is not captured.
    target_chroot pacman -S --needed --noconfirm snap-pac
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

configure_target() {
    local firewall_profile account_entry account_home account_shell account_status account_uid

    printf '%s\n' "$hostname" >/mnt/etc/hostname

    write_target_file /etc/hosts 0644 <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain   $hostname
EOF

    sed -i "/^#$locale/s/^#//" /mnt/etc/locale.gen
    printf 'LANG=%s\n' "$locale" >/mnt/etc/locale.conf
    printf 'KEYMAP=%s\n' "$kblayout" >/mnt/etc/vconsole.conf
    ln -sf "/usr/share/zoneinfo/$timezone" /mnt/etc/localtime
    target_chroot hwclock --systohc || show_warn "hwclock --systohc failed; set the hardware clock manually after install"
    target_chroot locale-gen >/dev/null

    install -d -m 0755 /mnt/etc/systemd/network
    install -d -m 0755 /mnt/etc/systemd/system/systemd-networkd-wait-online.service.d
    copy_settings_file network /etc/systemd/network/20-wired.network
    copy_settings_file network /etc/systemd/system/systemd-networkd-wait-online.service.d/wait-for-only-one-interface.conf
    copy_settings_file network /etc/systemd/networkd.conf

    install -d -m 0755 /mnt/etc/iwd /mnt/etc/systemd/system/iwd.service.d
    copy_settings_file network /etc/systemd/network/25-wireless.network
    copy_settings_file network /etc/systemd/network/30-wireless.network
    copy_settings_file network /etc/iwd/main.conf
    copy_settings_file network /etc/systemd/system/iwd.service.d/override.conf
    enable_target_service iwd.service

    copy_settings_file network /etc/systemd/resolved.conf
    enable_target_service systemd-networkd.service
    enable_target_service systemd-resolved.service
    enable_target_service systemd-timesyncd.service
    enable_target_service systemd-networkd-wait-online.service

    for firewall_profile in blackout drop general; do
        copy_settings_file network "/usr/local/share/firewall-profiles/$firewall_profile.nft"
        target_chroot nft --check --file "/usr/local/share/firewall-profiles/$firewall_profile.nft"
    done
    copy_settings_source network/usr/local/share/firewall-profiles/drop.nft /etc/nftables.conf
    copy_settings_file network /usr/local/sbin/firewall-profile 0755
    enable_target_service nftables.service

    copy_settings_file network /etc/sysctl.d/99-firewall-settings.conf
    copy_settings_file power /etc/sysctl.d/99-watchdog-settings.conf
    copy_settings_file power /etc/sysctl.d/99-zram-settings.conf
    copy_settings_file security /etc/sysctl.d/99-hardening.conf
    copy_settings_file security /etc/modprobe.d/blacklist.conf
    copy_settings_file security /etc/modprobe.d/disable-firewire.conf
    copy_settings_file security /etc/modprobe.d/disable-intel-mei.conf
    copy_settings_file hardware /etc/modprobe.d/iwlwifi.conf
    copy_settings_file security /etc/modprobe.d/security-blacklist.conf
    copy_settings_file security /etc/audit/auditd.conf
    copy_settings_file security /etc/audit/rules.d/10-arch-base.rules
    copy_settings_file security /etc/systemd/system.conf.d/60-disable-coredump.conf
    copy_settings_file security /etc/systemd/user.conf.d/60-disable-coredump.conf
    copy_settings_file security /etc/security/limits.d/60-disable-coredump.conf
    copy_settings_file access /etc/polkit-1/rules.d/00-udisks-wheel.rules

    install -d -m 0755 /mnt/etc/apparmor/earlypolicy
    install -d -m 0755 /mnt/etc/apparmor.d/local
    touch /mnt/etc/apparmor/parser.conf
    append_settings_file security /etc/apparmor/parser.conf
    enable_target_service apparmor.service
    enable_target_service auditd.service

    if [[ "$disable_bluetooth" == "yes" ]]; then
        copy_settings_file hardware /etc/modprobe.d/disable-bluetooth.conf
    fi

    if [[ "$disable_thunderbolt" == "yes" ]]; then
        copy_settings_file hardware /etc/modprobe.d/disable-thunderbolt.conf
    fi

    copy_settings_file hardware /etc/fwupd/fwupd.conf

    copy_settings_file power /etc/systemd/zram-generator.conf

    copy_settings_file power /etc/systemd/logind.conf.d/no-sleep.conf
    copy_settings_file power /etc/systemd/sleep.conf.d/no-sleep.conf
    mask_target_unit suspend.target
    mask_target_unit hibernate.target
    mask_target_unit hybrid-sleep.target
    mask_target_unit suspend-then-hibernate.target

    sed -Ei 's/^#(Color)$/\1\nILoveCandy/;s/^#(ParallelDownloads).*/\1 = 10/' /mnt/etc/pacman.conf

    if target_chroot getent group polkitd >/dev/null; then
        target_chroot chown root:polkitd /etc/polkit-1/rules.d
        target_chroot chmod 0750 /etc/polkit-1/rules.d
        target_chroot chown root:polkitd /etc/polkit-1/rules.d/00-udisks-wheel.rules
        target_chroot chmod 0640 /etc/polkit-1/rules.d/00-udisks-wheel.rules
    fi

    install -d -m 0755 /mnt/boot /mnt/efi/EFI/Linux /mnt/efi/loader /mnt/etc/cmdline.d /mnt/etc/mkinitcpio.d
    install -D -m 0644 "$RESCUE_UKI_SOURCE" "/mnt$RESCUE_UKI_TARGET"
    copy_settings_file boot /efi/loader/loader.conf

    copy_settings_file boot /etc/cmdline.d/defaults.conf
    copy_settings_file boot /etc/cmdline.d/security.conf
    copy_settings_file boot /etc/cmdline.d/iommu.conf
    copy_settings_file boot /etc/cmdline.d/filesystem.conf

    if [[ "$cpu_vendor" != "AuthenticAMD" ]]; then
        copy_settings_file boot /etc/cmdline.d/intel.conf
    fi

    copy_settings_file boot /etc/cmdline.d/lockdown.conf

    case "$unlock_method" in
        tpm2)
            printf 'cryptroot  UUID=%s  none  tpm2-device=auto,password-echo=no,x-systemd.device-timeout=0,timeout=0,no-read-workqueue,no-write-workqueue\n' "$root_uuid" >/mnt/etc/crypttab.initramfs
            ;;
        fido2)
            printf 'cryptroot  UUID=%s  none  fido2-device=auto,password-echo=no,x-systemd.device-timeout=30,timeout=0,no-read-workqueue,no-write-workqueue\n' "$root_uuid" >/mnt/etc/crypttab.initramfs
            ;;
        passphrase)
            printf 'cryptroot  UUID=%s  none  password-echo=no,x-systemd.device-timeout=0,timeout=0,no-read-workqueue,no-write-workqueue\n' "$root_uuid" >/mnt/etc/crypttab.initramfs
            ;;
    esac
    printf 'root=/dev/mapper/cryptroot\n' >/mnt/etc/cmdline.d/root.conf
    copy_settings_source boot/etc/mkinitcpio.conf.encrypted /etc/mkinitcpio.conf

    copy_settings_file boot /etc/mkinitcpio.d/linux.preset

    # Drop initramfs images generated by the stock presets during pacstrap;
    # nothing references them once the UKI presets take over.
    rm -f /mnt/boot/initramfs-*.img

    target_chroot mkinitcpio -P

    enable_target_service tailscaled.service
    enable_target_service pcscd.service

    if target_chroot id -u "$username" &>/dev/null; then
        show_error "Refusing to reuse existing target account: $username"
        return 1
    fi
    target_chroot useradd -m -G users,wheel -s /bin/bash "$username"

    printf '%s:%s\n' "$username" "$userpass" | target_chroot chpasswd

    copy_settings_file access /etc/sudoers.d/wheel 0440

    account_uid=$(target_chroot id -u "$username")
    account_entry=$(target_chroot getent passwd "$username")
    IFS=: read -r _ _ _ _ _ account_home account_shell <<<"$account_entry"
    account_status=$(target_chroot passwd -S "$username" | awk '{print $2}')
    (( account_uid >= 1000 )) || { show_error "$username does not have a regular-user UID"; return 1; }
    [[ "$account_home" == "/home/$username" && "$account_shell" == /bin/bash ]] || { show_error "$username has an unexpected home or login shell"; return 1; }
    target_chroot id -nG "$username" | tr ' ' '\n' | grep -qx wheel || { show_error "$username is not a member of wheel"; return 1; }
    [[ "$account_status" == P ]] || { show_error "$username does not have a usable password"; return 1; }
    target_chroot visudo -cf /etc/sudoers >/dev/null

    setup_snapper_rollback
    target_chroot passwd -l root >/dev/null

    if [[ "$unlock_method" != "passphrase" ]]; then
        show_section "LUKS Token Enrollment"
    fi

    case "$unlock_method" in
        tpm2)
            show_action "ACTION REQUIRED: TPM2 + PIN" \
                "When asked for the existing LUKS passphrase," \
                "enter the password for $username." \
                "The temporary password slot is removed after enrollment."
            target_chroot systemd-cryptenroll "$root_part" \
                --wipe-slot=password \
                --tpm2-device=auto \
                --tpm2-with-pin=yes \
                --tpm2-pcrs=
            show_success "TPM2 + PIN enrolled for LUKS unlock."
            ;;
        fido2)
            show_action "ACTION REQUIRED: INSERT FIDO2 KEY" \
                "Insert your FIDO2 key now." \
                "Press Enter when the key is ready."
            read -r
            show_action "ACTION REQUIRED: LUKS PASSPHRASE" \
                "When asked for the existing LUKS passphrase," \
                "enter the password for $username." \
                "The temporary password slot is removed after enrollment."
            target_chroot systemd-cryptenroll "$root_part" \
                --wipe-slot=password \
                --fido2-device=auto \
                --fido2-with-client-pin=yes \
                --fido2-credential-algorithm=eddsa
            show_success "FIDO2 + PIN enrolled for LUKS unlock."
            ;;
    esac

    # The chroot work above uses the live environment's bound resolv.conf.
    # Hand resolution to systemd-resolved before firmware enrollment, which is
    # the final irreversible installation step.
    ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

    show_section "Secure Boot Enrollment"
    if target_chroot sbctl status | grep -q 'Setup Mode:.*Enabled'; then
        target_chroot sbctl create-keys

        # Sign the systemd-boot source first so bootctl copies an already
        # signed binary to the ESP, and so future systemd updates re-sign it
        # via the sbctl pacman hook before systemd-boot-update copies it.
        target_chroot sbctl sign -s \
            -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi

        target_chroot bootctl --esp-path=/efi --variables=no install

        target_chroot sbctl sign -s /efi/EFI/systemd/systemd-bootx64.efi
        target_chroot sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI
        target_chroot sbctl sign -s /efi/EFI/Linux/arch-linux.efi
        target_chroot sbctl sign -s "$RESCUE_UKI_TARGET"

        delete_boot_entries_by_label "arch-linux"
        delete_boot_entries_by_label "arch-rescue"
        delete_boot_entries_by_label "Linux Boot Manager"
        target_chroot efibootmgr --create \
            --disk "$target_disk" \
            --part 1 \
            --label "Linux Boot Manager" \
            --loader "\\EFI\\systemd\\systemd-bootx64.efi" \
            --unicode

        if [[ -f /mnt/usr/lib/fwupd/efi/fwupdx64.efi ]]; then
            target_chroot sbctl sign -s -o /usr/lib/fwupd/efi/fwupdx64.efi.signed /usr/lib/fwupd/efi/fwupdx64.efi
        fi
        verify_target_efi_signature /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed
        verify_target_efi_signature /efi/EFI/systemd/systemd-bootx64.efi
        verify_target_efi_signature /efi/EFI/BOOT/BOOTX64.EFI
        verify_target_efi_signature /efi/EFI/Linux/arch-linux.efi
        verify_target_efi_signature "$RESCUE_UKI_TARGET"
        if [[ -f /mnt/usr/lib/fwupd/efi/fwupdx64.efi ]]; then
            verify_target_efi_signature /usr/lib/fwupd/efi/fwupdx64.efi.signed
        fi
        target_chroot sbctl enroll-keys -m
        secure_boot_status=$(target_chroot sbctl status)
        grep -q 'Setup Mode:.*Disabled' <<<"$secure_boot_status" || { show_error "Secure Boot keys were enrolled but firmware still reports Setup Mode"; return 1; }
    else
        show_error "Secure Boot is not in setup mode"
        return 1
    fi

}

show_header

kblayout=us
locale=en_US.UTF-8
loadkeys "$kblayout" || show_warn "Could not load keymap $kblayout (no console access?); continuing"

show_section "LUKS Unlock"
unlock_choices=("FIDO2 + PIN" "Passphrase only")
if [[ -c /dev/tpmrm0 ]]; then
    unlock_choices=("TPM2 + PIN" "${unlock_choices[@]}")
fi
unlock_method_label=$(gum choose --header "Select mandatory LUKS unlock method:" "${unlock_choices[@]}")
case "$unlock_method_label" in
    "TPM2 + PIN") unlock_method=tpm2 ;;
    "FIDO2 + PIN") unlock_method=fido2 ;;
    "Passphrase only") unlock_method=passphrase ;;
esac

show_section "Secure Boot"
setup_mode=$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ')
if [[ "$setup_mode" != "1" ]]; then
    show_error "Secure Boot Setup Mode is not enabled. Clear firmware Secure Boot keys and re-run the installer."
    exit 1
fi
show_info "Secure Boot setup is mandatory and firmware Setup Mode is enabled"
show_info "Kernel lockdown integrity mode is mandatory"

show_section "Hardware"
if gum confirm "Disable Bluetooth?"; then
    disable_bluetooth=yes
else
    disable_bluetooth=no
fi

if gum confirm "Disable Thunderbolt?"; then
    disable_thunderbolt=yes
else
    disable_thunderbolt=no
fi

show_section "Hostname"
while true; do
    hostname=$(gum input --header "Enter hostname:" --placeholder "archlinux" --char-limit 63)
    [[ -n "$hostname" ]] || { show_error "You need to enter a hostname"; continue; }
    [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { show_error "Invalid hostname"; continue; }
    break
done

show_section "Timezone"
tz_region=$(find /usr/share/zoneinfo -maxdepth 1 -type d \
    -not -name 'zoneinfo' -not -name 'posix' -not -name 'right' \
    -printf '%f\n' 2>/dev/null | sort | \
    gum filter --header "Select region:" --placeholder "Search region..." --height 15)
tz_city=$(find "/usr/share/zoneinfo/$tz_region" -type f -printf '%P\n' 2>/dev/null | sort | \
    gum filter --header "Select city:" --placeholder "Search city..." --height 15)
timezone="$tz_region/$tz_city"

show_section "User Account"
while true; do
    username=$(gum input --header "Enter username:" --placeholder "user")
    [[ -n "$username" ]] || { show_error "You need to enter a username"; continue; }
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { show_error "Invalid username"; continue; }
    [[ "$username" != root ]] || { show_error "root cannot be used as the regular account"; continue; }
    if getent passwd "$username" >/dev/null; then
        show_error "$username already exists in the live environment; choose a new regular-account name"
        continue
    fi
    break
done

while true; do
    userpass=$(gum input --password --header "Enter password for $username:")
    [[ -n "$userpass" ]] || { show_error "You need to enter a password"; continue; }
    userpass2=$(gum input --password --header "Confirm password for $username:")
    [[ "$userpass" == "$userpass2" ]] || { show_error "Passwords do not match"; continue; }
    break
done

show_section "Target Disk"
devices=$(lsblk --nodeps --paths --list --noheadings --sort=size --output=name,size,type,model | awk '$3 == "disk"')
if [[ -z "$devices" ]]; then
    show_error "No target disks found"
    exit 1
fi
while true; do
    target_disk=$(printf '%s\n' "$devices" | gum choose --header "Select disk to fully erase and install Arch onto:" | awk '{print $1}')
    if validate_disk_target "$target_disk"; then
        break
    fi
done
capture_target_identity

if (( target_disk_size < MINIMUM_DISK_BYTES )); then
    show_error "$target_disk is smaller than the required 32 GiB minimum"
    exit 1
fi

detect_gpu_package_files
collect_selected_packages
preflight_validate_packages
preflight_validate_rescue_uki

wipe_mode=none
if gum confirm "Discard all blocks on $target_disk before partitioning? This is destructive but is not a guaranteed secure erase."; then
    discard_max=$(lsblk --noheadings --nodeps --bytes --output DISC-MAX "$target_disk" | xargs)
    if [[ "$discard_max" =~ ^[0-9]+$ ]] && (( discard_max > 0 )); then
        wipe_mode=discard
    else
        show_error "$target_disk does not report discard support"
        exit 1
    fi
fi

show_section "Installation Summary"
gum style --border rounded --border-foreground "$UI_ACCENT" --padding "1 2" --margin "0 2" \
    "Target disk:     $target_disk" \
    "Block discard:   $wipe_mode" \
    "Unlock method:   $unlock_method_label" \
    "Bluetooth off:   $disable_bluetooth" \
    "Thunderbolt off: $disable_thunderbolt" \
    "Hostname:        $hostname" \
    "Timezone:        $timezone" \
    "Username:        $username"

show_action "DESTRUCTIVE OPERATION" \
    "All data on $target_disk will be destroyed."
if ! gum confirm "Erase $target_disk and begin installation?"; then
    show_info "Installation cancelled"
    exit 0
fi

if gum confirm "Review/delete existing EFI firmware boot entries before install?"; then
    manage_efi_boot_entries
fi

show_section "Disk Setup"
revalidate_target_identity
if [[ "$wipe_mode" == "discard" ]]; then
    show_info "Discarding all blocks on $target_disk"
    blkdiscard -f "$target_disk"
fi

show_info "Creating declarative full-disk GPT layout with sfdisk"
sfdisk --wipe always --wipe-partitions always "$target_disk" <<'EOF'
label: gpt
size=2GiB, type=uefi, name=ESP
type=linux, name=ROOT
EOF
partprobe "$target_disk"
udevadm settle

efi_part=$(partition_path "$target_disk" 1)
root_part=$(partition_path "$target_disk" 2)
verify_partition_layout

show_info "Formatting ESP $efi_part"
wipefs --all "$efi_part"
mkfs.fat -F 32 -n EFI "$efi_part"

show_info "Preparing root partition $root_part"
if cryptsetup isLuks "$root_part"; then
    cryptsetup -q erase "$root_part"
fi
wipefs --all "$root_part" 2>/dev/null || true

printf '%s' "$userpass" | cryptsetup -q -c aes-xts-plain64 -s 512 -h sha512 luksFormat "$root_part" -d -
cryptroot_opened=opening
printf '%s' "$userpass" | cryptsetup open "$root_part" cryptroot -d -
cryptroot_opened=yes
root_device=/dev/mapper/cryptroot

mkfs.btrfs -f -L linux "$root_device"

show_info "Mounting target filesystems"
target_mounted=mounting
mount "$root_device" /mnt
target_mounted=yes
for subvolume in "${BTRFS_SUBVOLUMES[@]}"; do
    btrfs subvolume create "/mnt/$subvolume"
done
umount /mnt
target_mounted=no

target_mounted=mounting
mount -o "$BTRFS_MOUNT_OPTIONS,subvol=@" "$root_device" /mnt
target_mounted=yes
for subvolume_mount in "${BTRFS_SUBVOLUME_MOUNTS[@]}"; do
    subvolume=${subvolume_mount%%:*}
    mountpoint=${subvolume_mount#*:}
    mount_options=$(btrfs_mount_options_for "$mountpoint")
    install -d -m 0755 "/mnt$mountpoint"
    mount -o "$mount_options,subvol=$subvolume" "$root_device" "/mnt$mountpoint"
done
chmod 0700 /mnt/root
chmod 1777 /mnt/var/tmp
install -d -m 0755 /mnt/efi
mount -o "$EFI_MOUNT_OPTIONS" "$efi_part" /mnt/efi

detect_microcode
show_section "Base System"
show_info "Installing base system with pacstrap"
pacstrap -K /mnt \
    base base-devel linux linux-headers "$microcode" linux-firmware

show_info "Generating fstab"
genfstab -U /mnt >/mnt/etc/fstab

root_uuid=$(blkid -s UUID -o value "$root_part")

show_section "Package Installation"
install_selected_packages

show_section "System Configuration"
show_info "Configuring target system"
configure_target
unset userpass userpass2

show_section "Finalizing Installation"
umount -R /mnt
target_mounted=no
cryptsetup close cryptroot
cryptroot_opened=no

echo ""
gum style \
    --foreground "$UI_SUCCESS" --border-foreground "$UI_SUCCESS" --border double \
    --align center --width "$UI_WIDTH" --margin "1 2" --padding "1 2" \
    "Installation Complete" \
    "" \
    "Reboot into firmware and enable Secure Boot:" \
    "systemctl reboot --firmware-setup"
