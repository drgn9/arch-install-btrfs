#!/usr/bin/env bash

clear
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_DIR="$SCRIPT_DIR/settings"
RESCUE_UKI_SOURCE="$SCRIPT_DIR/artifacts/arch-rescue.efi"
RESCUE_UKI_TARGET=/efi/EFI/Linux/arch-rescue.efi

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

configure_target() {
    local firewall_profile

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
            printf 'cryptroot  UUID=%s  none  tpm2-device=auto,password-echo=no,x-systemd.device-timeout=0,timeout=0,no-read-workqueue,no-write-workqueue,discard\n' "$root_uuid" >/mnt/etc/crypttab.initramfs
            ;;
        fido2)
            printf 'cryptroot  UUID=%s  none  fido2-device=auto,password-echo=no,x-systemd.device-timeout=30,timeout=0,no-read-workqueue,no-write-workqueue,discard\n' "$root_uuid" >/mnt/etc/crypttab.initramfs
            ;;
        passphrase)
            printf 'cryptroot  UUID=%s  none  password-echo=no,x-systemd.device-timeout=0,timeout=0,no-read-workqueue,no-write-workqueue,discard\n' "$root_uuid" >/mnt/etc/crypttab.initramfs
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
    enable_target_service fstrim.timer
    enable_target_service systemd-boot-update.service

    if ! target_chroot id -u "$username" &>/dev/null; then
        target_chroot useradd -m -G users,wheel -s /bin/bash "$username"
    else
        target_chroot usermod -aG users,wheel "$username"
    fi

    printf '%s:%s\n' "$username" "$userpass" | target_chroot chpasswd

    copy_settings_file access /etc/sudoers.d/wheel 0440

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

    show_section "Secure Boot Enrollment"
    if target_chroot sbctl status | grep -q 'Setup Mode:.*Enabled'; then
        target_chroot sbctl create-keys
        target_chroot sbctl enroll-keys -m

        # Sign the systemd-boot source first so bootctl copies an already
        # signed binary to the ESP, and so future systemd updates re-sign it
        # via the sbctl pacman hook before systemd-boot-update copies it.
        sign_target_file /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed

        target_chroot bootctl --esp-path=/efi --variables=no install

        sign_target_file /efi/EFI/systemd/systemd-bootx64.efi
        sign_target_file /efi/EFI/BOOT/BOOTX64.EFI
        sign_target_file /efi/EFI/Linux/arch-linux.efi
        sign_target_file "$RESCUE_UKI_TARGET"

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
            sign_target_file /usr/lib/fwupd/efi/fwupdx64.efi /usr/lib/fwupd/efi/fwupdx64.efi.signed
        fi
        target_chroot sbctl verify
        target_chroot sbctl status || true
    else
        show_error "Secure Boot is not in setup mode"
        exit 1
    fi

    # Deferred to the end: the chroot steps above need working DNS, which the
    # live environment provides by bind-mounting its resolv.conf over a
    # regular file. Only now hand resolution over to systemd-resolved.
    ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
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

detect_gpu_package_files
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
wipefs --all "$efi_part"
mkfs.fat -F 32 -n EFI "$efi_part"

show_info "Preparing root partition $root_part"
if cryptsetup isLuks "$root_part"; then
    cryptsetup -q erase "$root_part"
fi
wipefs --all "$root_part" 2>/dev/null || true

printf '%s' "$userpass" | cryptsetup -q -c aes-xts-plain64 -s 512 -h sha512 luksFormat "$root_part" -d -
printf '%s' "$userpass" | cryptsetup open "$root_part" cryptroot -d -
root_device=/dev/mapper/cryptroot

mkfs.btrfs -f -L linux "$root_device"

show_info "Mounting target filesystems"
mount "$root_device" /mnt
for subvolume in "${BTRFS_SUBVOLUMES[@]}"; do
    btrfs subvolume create "/mnt/$subvolume"
done
umount /mnt

mount -o "$BTRFS_MOUNT_OPTIONS,subvol=@" "$root_device" /mnt
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
