#!/usr/bin/env bash

clear
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_DIR="$SCRIPT_DIR/settings"
BTRFS_MOUNT_OPTIONS="noatime,compress=zstd:3"
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
    @sbctl
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
    "@sbctl:/var/lib/sbctl"
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

connect_wifi_guided() {
    local device ssid passphrase attempt
    local wifi_devices=()

    if ! command -v iwctl &>/dev/null; then
        echo "iwctl is not available. Connect to the network manually, then choose re-check." >&2
        return 1
    fi

    rfkill unblock wifi 2>/dev/null || true

    mapfile -t wifi_devices < <(iwctl device list | sed 's/\x1b\[[0-9;]*m//g' | awk 'NR > 4 && NF { print $1 }')
    if (( ${#wifi_devices[@]} == 0 )); then
        echo "No wireless devices found." >&2
        return 1
    fi

    device=${wifi_devices[0]}
    if (( ${#wifi_devices[@]} > 1 )); then
        echo "Wireless devices: ${wifi_devices[*]}"
        read -rp "Device to use [${wifi_devices[0]}]: " device
        device=${device:-${wifi_devices[0]}}
    fi

    echo "Scanning for networks on $device..."
    iwctl station "$device" scan 2>/dev/null || true
    sleep 4
    iwctl station "$device" get-networks || true

    read -rp "Network name (SSID): " ssid
    if [[ -z "$ssid" ]]; then
        echo "No network name entered." >&2
        return 1
    fi
    read -rsp "Passphrase (leave empty for an open network): " passphrase
    echo ""

    if [[ -n "$passphrase" ]]; then
        iwctl --passphrase "$passphrase" station "$device" connect "$ssid"
    else
        iwctl station "$device" connect "$ssid"
    fi
    unset passphrase

    echo "Waiting for the connection to come up..."
    for ((attempt = 0; attempt < 15; attempt++)); do
        if have_network; then
            return 0
        fi
        sleep 2
    done
    echo "Connected to $ssid but no internet access yet." >&2
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
        echo "  1) Connect to Wi-Fi (guided)"
        echo "  2) Re-check (choose this after plugging in an ethernet cable)"
        echo "  3) Abort"
        read -rp "Choice [1]: " choice
        case "${choice:-1}" in
            1) connect_wifi_guided || echo "Wi-Fi setup did not succeed. Try again." >&2 ;;
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
for dep in gum cryptsetup efibootmgr sfdisk wipefs blkdiscard partprobe mkfs.fat mkfs.btrfs btrfs lspci pacstrap arch-chroot genfstab; do
    command -v "$dep" &>/dev/null || deps_needed+=("$dep")
done

if [[ ${#deps_needed[@]} -gt 0 ]]; then
    echo "Installing live environment dependencies: ${deps_needed[*]}"
    pacman -S --needed --noconfirm gum cryptsetup efibootmgr util-linux dosfstools btrfs-progs parted pciutils arch-install-scripts
fi

show_header() {
    clear
    gum style \
        --foreground 212 --border-foreground 212 --border double \
        --align center --width 74 --margin "1 2" --padding "1 2" \
        "Arch New Installer" \
        "" \
        "Niri-only Btrfs + UKI + EFISTUB"
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
    rm -f /mnt/etc/sudoers.d/99-installer-aur-nopasswd 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
    cryptsetup close to_be_wiped 2>/dev/null || true
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
    if [[ "$use_docker_packages" == "yes" ]]; then
        selected_package_files+=(packages/base-docker.conf)
    fi

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
    show_info "Validating ${#selected_packages[@]} package names from: ${selected_package_files[*]}"
    if ! pacman -Sp --print-format '%n' "${selected_packages[@]}" >/dev/null; then
        show_error "Unresolvable package names found. Fix the package files and re-run."
        exit 1
    fi
}

install_selected_packages() {
    local packages=()
    local package

    for package in "${selected_packages[@]}"; do
        [[ "$package" == snap-pac ]] && continue
        packages+=("$package")
    done

    show_info "Installing ${#packages[@]} packages into the target; snap-pac is deferred until Snapper is configured"
    target_chroot pacman -S --needed --noconfirm "${packages[@]}"
}

setup_snapper_rollback() {
    show_info "Configuring Snapper rollback"

    umount /mnt/.snapshots
    rmdir /mnt/.snapshots
    target_chroot snapper -c root create-config /
    target_chroot btrfs subvolume delete /.snapshots

    install -d -m 0750 /mnt/.snapshots
    mount -o "$BTRFS_MOUNT_OPTIONS,subvol=@snapshots" "$root_device" /mnt/.snapshots
    chmod 0750 /mnt/.snapshots

    target_chroot snapper -c root set-config \
        TIMELINE_CREATE=no \
        TIMELINE_CLEANUP=no \
        NUMBER_CLEANUP=yes \
        NUMBER_LIMIT=20 \
        NUMBER_LIMIT_IMPORTANT=5 \
        EMPTY_PRE_POST_CLEANUP=yes
    enable_target_service snapper-cleanup.timer

    copy_settings_file rollback /usr/local/sbin/arch-rollback 0755

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

delete_boot_entries_by_label() {
    local label=$1
    local boot_num

    while read -r boot_num; do
        [[ -n "$boot_num" ]] || continue
        target_chroot efibootmgr --bootnum "$boot_num" --delete-bootnum --unicode || true
    done < <(target_chroot efibootmgr --unicode 2>/dev/null | awk -v label="$label" '$1 ~ /^Boot[0-9A-Fa-f]{4}\*?$/ && $2 == label { sub(/^Boot/, "", $1); sub(/\*.*/, "", $1); print $1 }')
}

configure_target() {
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
    target_chroot hwclock --systohc
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

    # Carry Wi-Fi credentials from the live session into the target so the
    # network joined during installation works on first boot.
    mapfile -t iwd_known_networks < <(find /var/lib/iwd -maxdepth 1 -type f \
        \( -name '*.psk' -o -name '*.open' -o -name '*.8021x' \) 2>/dev/null)
    if (( ${#iwd_known_networks[@]} > 0 )); then
        show_info "Copying ${#iwd_known_networks[@]} iwd known network(s) into the target"
        install -d -m 0700 /mnt/var/lib/iwd
        cp -a -- "${iwd_known_networks[@]}" /mnt/var/lib/iwd/
    fi

    copy_settings_file network /etc/systemd/resolved.conf
    enable_target_service systemd-networkd.service
    enable_target_service systemd-resolved.service
    enable_target_service systemd-timesyncd.service

    copy_settings_file network /etc/sysctl.d/99-firewall-settings.conf
    copy_settings_file power /etc/sysctl.d/99-watchdog-settings.conf
    copy_settings_file power /etc/sysctl.d/99-zram-settings.conf
    copy_settings_file security /etc/sysctl.d/99-hardening.conf
    copy_settings_file security /etc/modprobe.d/blacklist.conf
    copy_settings_file security /etc/modprobe.d/disable-firewire.conf
    copy_settings_file security /etc/modprobe.d/disable-intel-mei.conf
    copy_settings_file hardware /etc/modprobe.d/iwlwifi.conf
    copy_settings_file security /etc/modprobe.d/security-blacklist.conf
    copy_settings_file security /etc/audit/rules.d/10-arch-base.rules
    copy_settings_file security /etc/systemd/system.conf.d/60-disable-coredump.conf
    copy_settings_file security /etc/systemd/user.conf.d/60-disable-coredump.conf
    copy_settings_file security /etc/security/limits.d/60-disable-coredump.conf
    copy_settings_file access /etc/polkit-1/rules.d/00-udisks-wheel.rules

    install -d -m 0755 /mnt/etc/apparmor/earlypolicy
    install -d -m 0755 /mnt/etc/apparmor.d/tunables/xdg-user-dirs.d/apparmor.d.d
    install -d -m 0755 /mnt/etc/apparmor.d/local
    touch /mnt/etc/apparmor/parser.conf
    append_settings_file security /etc/apparmor/parser.conf
    copy_settings_file security /etc/apparmor.d/tunables/xdg-user-dirs.d/apparmor.d.d/local
    enable_target_service apparmor.service
    enable_target_service auditd.service

    if [[ "$disable_bluetooth" == "yes" ]]; then
        copy_settings_file hardware /etc/modprobe.d/disable-bluetooth.conf
    fi

    if [[ "$disable_thunderbolt" == "yes" ]]; then
        copy_settings_file hardware /etc/modprobe.d/disable-thunderbolt.conf
    fi

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

    install -d -m 0755 /mnt/boot /mnt/efi/EFI/Linux /mnt/etc/cmdline.d /mnt/etc/mkinitcpio.d

    copy_settings_file boot /etc/cmdline.d/defaults.conf
    copy_settings_file boot /etc/cmdline.d/security.conf
    copy_settings_file boot /etc/cmdline.d/iommu.conf
    copy_settings_file boot /etc/cmdline.d/filesystem.conf

    if [[ "$cpu_vendor" != "AuthenticAMD" ]]; then
        copy_settings_file boot /etc/cmdline.d/intel.conf
    fi

    if [[ "$use_lockdown" == "yes" ]]; then
        copy_settings_file boot /etc/cmdline.d/lockdown.conf
    fi

    if [[ "$encrypt_root" == "yes" ]]; then
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
    else
        printf 'root=UUID=%s\n' "$root_uuid" >/mnt/etc/cmdline.d/root.conf
        copy_settings_source boot/etc/mkinitcpio.conf.plain /etc/mkinitcpio.conf
    fi

    copy_settings_file boot /etc/mkinitcpio.d/linux.preset
    copy_settings_file boot /etc/mkinitcpio.d/linux-lts.preset

    # Drop initramfs images generated by the stock presets during pacstrap;
    # nothing references them once the UKI presets take over.
    rm -f /mnt/boot/initramfs-*.img

    target_chroot mkinitcpio -P

    delete_boot_entries_by_label "arch-linux"
    delete_boot_entries_by_label "arch-linux-lts"
    target_chroot efibootmgr --create --disk "$target_disk" --part 1 --label "arch-linux-lts" --loader "\\EFI\\Linux\\arch-linux-lts.efi" --unicode
    target_chroot efibootmgr --create --disk "$target_disk" --part 1 --label "arch-linux" --loader "\\EFI\\Linux\\arch-linux.efi" --unicode

    enable_target_service tailscaled.service
    enable_target_service pcscd.service

    if ! target_chroot id -u "$username" &>/dev/null; then
        target_chroot useradd -m -G users,wheel -s /bin/bash "$username"
    else
        target_chroot usermod -aG users,wheel "$username"
    fi

    printf '%s:%s\n' "$username" "$userpass" | target_chroot chpasswd

    printf '%%wheel ALL=(ALL) NOPASSWD: ALL\n' >/mnt/etc/sudoers.d/99-installer-aur-nopasswd
    chmod 0440 /mnt/etc/sudoers.d/99-installer-aur-nopasswd

    if ! target_chroot bash -lc 'command -v yay >/dev/null 2>&1'; then
        # shellcheck disable=SC2016
        target_chroot runuser -u "$username" -- bash -lc '
            set -euo pipefail
            tmpdir=$(mktemp -d)
            trap "rm -rf \"$tmpdir\"" EXIT
            git clone https://aur.archlinux.org/yay-bin.git "$tmpdir/yay-bin" >/dev/null
            cd "$tmpdir/yay-bin"
            makepkg -si --noconfirm >/dev/null
        '
    fi

    rm -f /mnt/etc/sudoers.d/99-installer-aur-nopasswd
    copy_settings_file access /etc/sudoers.d/wheel 0440

    setup_snapper_rollback
    target_chroot passwd -l root >/dev/null

    if [[ "$encrypt_root" == "yes" ]]; then
        case "$unlock_method" in
            tpm2)
                echo "Enrolling TPM2 LUKS key with PIN. The install user's password authorizes enrollment and is removed afterward."
                target_chroot systemd-cryptenroll "$root_part" \
                    --wipe-slot=password \
                    --tpm2-device=auto \
                    --tpm2-with-pin=yes \
                    --tpm2-pcrs=
                show_info "Only TPM2+PIN remains enrolled for LUKS unlock. Add backup methods post-install with systemd-cryptenroll."
                ;;
            fido2)
                echo "Insert your FIDO2 key, then press Enter to enroll it with a PIN."
                read -r
                echo "The install user's password authorizes enrollment and is removed afterward."
                target_chroot systemd-cryptenroll "$root_part" \
                    --wipe-slot=password \
                    --fido2-device=auto \
                    --fido2-with-client-pin=yes \
                    --fido2-credential-algorithm=eddsa
                show_info "Only FIDO2+PIN remains enrolled for LUKS unlock. Add backup methods post-install with systemd-cryptenroll."
                ;;
        esac
    fi

    if [[ "$secure_boot" == "yes" ]]; then
        if target_chroot sbctl status | grep -q 'Setup Mode:.*Enabled'; then
            target_chroot sbctl create-keys
            target_chroot sbctl enroll-keys -m
            target_chroot sbctl sign -s /efi/EFI/Linux/arch-linux.efi
            target_chroot sbctl sign -s /efi/EFI/Linux/arch-linux-lts.efi
            if [[ -f /mnt/usr/lib/fwupd/efi/fwupdx64.efi ]]; then
                target_chroot sbctl sign -s /usr/lib/fwupd/efi/fwupdx64.efi
            fi
            target_chroot sbctl verify
            target_chroot sbctl status || true
        else
            show_error "Secure Boot is not in setup mode"
            exit 1
        fi
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

gum style --foreground 212 --bold --margin "1 0" "LUKS Encryption"
if gum confirm "Encrypt the root partition?"; then
    encrypt_root=yes
else
    encrypt_root=no
fi

if [[ "$encrypt_root" == "yes" ]]; then
    unlock_choices=("FIDO2 + PIN" "Passphrase only")
    if [[ -c /dev/tpmrm0 ]]; then
        unlock_choices=("TPM2 + PIN" "${unlock_choices[@]}")
    fi
    unlock_method_label=$(gum choose --header "Select LUKS unlock method:" "${unlock_choices[@]}")
    case "$unlock_method_label" in
        "TPM2 + PIN") unlock_method=tpm2 ;;
        "FIDO2 + PIN") unlock_method=fido2 ;;
        "Passphrase only") unlock_method=passphrase ;;
    esac
else
    unlock_method=none
fi

gum style --foreground 212 --bold --margin "1 0" "Secure Boot"
if gum confirm "Enable Secure Boot?"; then
    secure_boot=yes
    setup_mode=$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ')
    if [[ "$setup_mode" != "1" ]]; then
        show_error "Secure Boot Setup Mode is not enabled. Clear firmware Secure Boot keys and re-run the installer."
        exit 1
    fi
else
    secure_boot=no
fi

gum style --foreground 212 --bold --margin "1 0" "Kernel Lockdown"
if gum confirm "Enable kernel lockdown (integrity mode)?"; then
    use_lockdown=yes
else
    use_lockdown=no
fi

gum style --foreground 212 --bold --margin "1 0" "Hardware"
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

gum style --foreground 212 --bold --margin "1 0" "Optional Packages"
if gum confirm "Install Docker packages?"; then
    use_docker_packages=yes
else
    use_docker_packages=no
fi

gum style --foreground 212 --bold --margin "1 0" "Hostname"
while true; do
    hostname=$(gum input --header "Enter hostname:" --placeholder "archlinux" --char-limit 63)
    [[ -n "$hostname" ]] || { show_error "You need to enter a hostname"; continue; }
    [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { show_error "Invalid hostname"; continue; }
    break
done

gum style --foreground 212 --bold --margin "1 0" "Timezone"
tz_region=$(find /usr/share/zoneinfo -maxdepth 1 -type d \
    -not -name 'zoneinfo' -not -name 'posix' -not -name 'right' \
    -printf '%f\n' 2>/dev/null | sort | \
    gum filter --header "Select region:" --placeholder "Search region..." --height 15)
tz_city=$(find "/usr/share/zoneinfo/$tz_region" -type f -printf '%P\n' 2>/dev/null | sort | \
    gum filter --header "Select city:" --placeholder "Search city..." --height 15)
timezone="$tz_region/$tz_city"

gum style --foreground 212 --bold --margin "1 0" "User Account"
while true; do
    username=$(gum input --header "Enter username:" --placeholder "user")
    [[ -n "$username" ]] || { show_error "You need to enter a username"; continue; }
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { show_error "Invalid username"; continue; }
    break
done

while true; do
    userpass=$(gum input --password --header "Enter password for $username:")
    [[ -n "$userpass" ]] || { show_error "You need to enter a password"; continue; }
    userpass2=$(gum input --password --header "Confirm password for $username:")
    [[ "$userpass" == "$userpass2" ]] || { show_error "Passwords do not match"; continue; }
    break
done

gum style --foreground 212 --bold --margin "1 0" "Target Disk"
devices=$(lsblk --nodeps --paths --list --noheadings --sort=size --output=name,size,type,model | awk '$3 == "disk"')
if [[ -z "$devices" ]]; then
    show_error "No target disks found"
    exit 1
fi
target_disk=$(printf '%s\n' "$devices" | gum choose --header "Select disk to fully erase and install Arch onto:" | awk '{print $1}')
validate_disk_target "$target_disk"

detect_gpu_package_files
collect_selected_packages
preflight_validate_packages

wipe_mode=none
if gum confirm "Securely wipe $target_disk before partitioning? This can take a long time."; then
    wipe_mode=zero
    if [[ "$(lsblk --nodeps --noheadings --output ROTA "$target_disk" | tr -d '[:space:]')" == "0" ]] &&
        gum confirm "$target_disk is an SSD. Use fast TRIM-based discard instead of a full overwrite?"; then
        wipe_mode=discard
    fi
fi

gum style --foreground 212 --bold --margin "1 0" "Installation Summary"
gum style --border rounded --border-foreground 212 --padding "1 2" --margin "0 2" \
    "Target disk:     $target_disk" \
    "Disk layout:     GPT: 1 GiB ESP + Btrfs root remainder" \
    "Secure wipe:     $wipe_mode" \
    "Encryption:      $encrypt_root" \
    "Unlock method:   $unlock_method" \
    "Secure Boot:     $secure_boot" \
    "AppArmor:        yes" \
    "Lockdown:        $use_lockdown" \
    "Bluetooth off:   $disable_bluetooth" \
    "Thunderbolt off: $disable_thunderbolt" \
    "Desktop:         Niri" \
    "Docker:          $use_docker_packages" \
    "Network:         iwd + systemd-networkd" \
    "GPU packages:    $gpu_label" \
    "Hostname:        $hostname" \
    "Timezone:        $timezone" \
    "Username:        $username"

if ! gum confirm "Proceed? This will destroy all data on $target_disk."; then
    show_info "Installation cancelled"
    exit 0
fi

if findmnt -rn /mnt >/dev/null 2>&1; then
    show_error "/mnt is already mounted. Unmount it before running the installer."
    exit 1
fi

if [[ -e /dev/mapper/cryptroot || -e /dev/mapper/to_be_wiped ]]; then
    show_error "An installer mapper already exists. Close cryptroot/to_be_wiped before running."
    exit 1
fi

if [[ "$wipe_mode" == "discard" ]]; then
    show_info "Discarding all blocks on $target_disk"
    wipefs --all "$target_disk"
    blkdiscard -f "$target_disk"
    partprobe "$target_disk" || true
    udevadm settle || true
elif [[ "$wipe_mode" == "zero" ]]; then
    show_info "Securely wiping $target_disk"
    wipefs --all "$target_disk"
    cryptsetup open --type plain -c aes-xts-plain64 -d /dev/urandom "$target_disk" to_be_wiped
    wipe_size=$(blockdev --getsize64 /dev/mapper/to_be_wiped)
    dd if=/dev/zero of=/dev/mapper/to_be_wiped bs=16M count="$wipe_size" iflag=count_bytes status=progress conv=fsync
    cryptsetup close to_be_wiped
    partprobe "$target_disk" || true
    udevadm settle || true
fi

show_info "Creating declarative full-disk GPT layout with sfdisk"
sfdisk --wipe always --wipe-partitions always "$target_disk" <<'EOF'
label: gpt
size=1GiB, type=uefi, name=ESP
type=linux, name=ROOT
EOF
partprobe "$target_disk" || true
udevadm settle || true

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

if [[ "$encrypt_root" == "yes" ]]; then
    printf '%s' "$userpass" | cryptsetup -q -c aes-xts-plain64 -s 512 -h sha512 luksFormat "$root_part" -d -
    printf '%s' "$userpass" | cryptsetup open "$root_part" cryptroot -d -
    root_device=/dev/mapper/cryptroot
else
    root_device="$root_part"
fi

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
    install -d -m 0755 "/mnt$mountpoint"
    mount -o "$BTRFS_MOUNT_OPTIONS,subvol=$subvolume" "$root_device" "/mnt$mountpoint"
done
chmod 0700 /mnt/root
chmod 1777 /mnt/var/tmp
install -d -m 0755 /mnt/efi
mount -o fmask=0137,dmask=0027 "$efi_part" /mnt/efi

detect_microcode
show_info "Installing base system with pacstrap"
pacstrap -K /mnt \
    base base-devel linux linux-headers linux-lts linux-lts-headers "$microcode" linux-firmware

show_info "Generating fstab"
genfstab -U /mnt >/mnt/etc/fstab

root_uuid=$(blkid -s UUID -o value "$root_part")

install_selected_packages

show_info "Configuring target system"
configure_target
unset userpass userpass2

echo ""
if [[ "$secure_boot" == "yes" ]]; then
    gum style \
        --foreground 82 --border-foreground 82 --border double \
        --align center --width 74 --margin "1 2" --padding "1 2" \
        "Installation Complete" \
        "" \
        "Reboot into firmware and enable Secure Boot:" \
        "systemctl reboot --firmware-setup"
else
    gum style \
        --foreground 82 --border-foreground 82 --border double \
        --align center --width 74 --margin "1 2" --padding "1 2" \
        "Installation Complete"
fi
