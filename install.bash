#!/usr/bin/env bash

clear
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_DIR="$SCRIPT_DIR/settings"
RESCUE_UKI_SOURCE="$SCRIPT_DIR/artifacts/arch-rescue.efi"

# shellcheck source=installer-common.bash
# shellcheck disable=SC1091
source "$SCRIPT_DIR/installer-common.bash"

if [[ ${EUID:-0} -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo "ERROR: This installer requires UEFI boot mode. Legacy BIOS is not supported." >&2
    exit 1
fi

ensure_network() {
    if have_network; then
        echo "Internet connection OK"
        return 0
    fi

    rfkill unblock wifi 2>/dev/null || true
    systemctl start iwd.service 2>/dev/null || true
    echo "No internet connection detected. The installer needs internet to download packages."
    show_wifi_instructions install-arch
    echo "Alternatively, plug in an ethernet cable and run install-arch again."
    exit 1
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

UI_ACCENT=212
UI_ACTION=214
UI_SUCCESS=82
UI_WIDTH=74

show_header() {
    clear
    gum style \
        --foreground "$UI_ACCENT" --border-foreground "$UI_ACCENT" --border double \
        --align center --width "$UI_WIDTH" --margin "1 2" --padding "1 2" \
        "Arch Installation (luks + btrfs + uki + systemd-boot)"
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

cleanup() {
    local line=$1
    local command=$2
    local status=$3

    show_error "Installation failed at line $line (exit $status): $command"
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    exit "$status"
}
trap 'cleanup "$LINENO" "$BASH_COMMAND" "$?"' ERR
trap 'cleanup "$LINENO" "interrupted" 130' INT TERM

device_has_mounts() {
    lsblk --noheadings --output MOUNTPOINTS "$1" | grep -q '[^[:space:]]'
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
}

preflight_validate_rescue_uki() {
    if [[ ! -f "$RESCUE_UKI_SOURCE" ]]; then
        show_error "Missing rescue UKI artifact: $RESCUE_UKI_SOURCE"
        show_error "Build the installer ISO with ./iso/build.sh so artifacts/arch-rescue.efi is included."
        exit 1
    fi
}

# Fresh-install-only steps: rescue UKI copy, LUKS token enrollment, and
# Secure Boot key creation/enrollment. Rescue reinstall keeps the rescue UKI,
# tokens, and keys that already exist.
enroll_unlock_and_secure_boot() {
    install -D -m 0644 "$RESCUE_UKI_SOURCE" "/mnt$RESCUE_UKI_TARGET"

    if [[ "$unlock_method" != "passphrase" ]]; then
        show_section "LUKS Token Enrollment"
    fi

    case "$unlock_method" in
        tpm2)
            show_action "ACTION REQUIRED: TPM2 + PIN" \
                "When asked for the existing LUKS passphrase," \
                "enter the password for $username." \
                "The password slot remains available as a fallback."
            target_chroot systemd-cryptenroll "$root_part" \
                --tpm2-device=auto \
                --tpm2-with-pin=yes \
                --tpm2-pcrs=
            show_success "TPM2 + PIN enrolled for LUKS unlock; passphrase fallback retained."
            ;;
        fido2)
            show_action "ACTION REQUIRED: INSERT FIDO2 KEY" \
                "Insert your FIDO2 key now." \
                "Press Enter when the key is ready."
            read -r
            show_action "ACTION REQUIRED: LUKS PASSPHRASE" \
                "When asked for the existing LUKS passphrase," \
                "enter the password for $username." \
                "The password slot remains available as a fallback." \
                "Remove it after enrolling and testing a backup FIDO2 key."
            target_chroot systemd-cryptenroll "$root_part" \
                --fido2-device=auto \
                --fido2-with-client-pin=yes \
                --fido2-credential-algorithm=eddsa
            show_success "FIDO2 + PIN enrolled for LUKS unlock; passphrase fallback retained."
            ;;
    esac

    show_section "Secure Boot Enrollment"
    # Setup Mode was verified before any disk work; enroll-keys fails if the
    # firmware has left it since.
    target_chroot sbctl create-keys
    target_chroot sbctl enroll-keys -m
    install_and_sign_boot_manager

    finalize_target_dns
}

show_header

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

prompt_system_settings

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

collect_selected_packages
preflight_validate_packages
preflight_validate_rescue_uki

wipe_mode=none
if gum confirm "Discard all blocks on $target_disk with blkdiscard before partitioning? This is destructive but not guaranteed secure erasure."; then
    wipe_mode=discard
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

if findmnt -rn /mnt >/dev/null 2>&1; then
    show_error "/mnt is already mounted. Unmount it before running the installer."
    exit 1
fi

if [[ -e /dev/mapper/cryptroot ]]; then
    show_error "An installer mapper already exists. Close cryptroot before running."
    exit 1
fi

show_section "Disk Setup"
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

show_info "Formatting ESP $efi_part"
mkfs.fat -F 32 -n EFI "$efi_part"

show_info "Encrypting root partition $root_part"
printf '%s' "$userpass" | cryptsetup -q -c aes-xts-plain64 -s 512 -h sha512 luksFormat "$root_part" -d -
printf '%s' "$userpass" | cryptsetup open "$root_part" cryptroot -d -
root_device=/dev/mapper/cryptroot

mkfs.btrfs -f -L linux "$root_device"

show_info "Mounting target filesystems"
mount "$root_device" /mnt
while read -r subvolume; do
    btrfs subvolume create "/mnt/$subvolume"
done < <(layout_subvolumes recreate keep ask)
umount /mnt

mount_target_layout

install_target_system
enroll_unlock_and_secure_boot
unset userpass userpass2

show_section "Finalizing Installation"
if ! umount -R /mnt; then
    show_error "Failed to unmount /mnt cleanly. Close open files on it, then run: umount -R /mnt"
fi
if ! cryptsetup close cryptroot; then
    show_error "Failed to close cryptroot. Close it manually before rebooting: cryptsetup close cryptroot"
fi

echo ""
gum style \
    --foreground "$UI_SUCCESS" --border-foreground "$UI_SUCCESS" --border double \
    --align center --width "$UI_WIDTH" --margin "1 2" --padding "1 2" \
    "Installation Complete" \
    "" \
    "Reboot into firmware and enable Secure Boot:" \
    "systemctl reboot --firmware-setup"
