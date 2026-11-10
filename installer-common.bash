# installer-common.bash - shared constants and helpers for the USB installer
# and the rescue reinstall path. Sourced, never executed.
# Constants defined here are used by sourcing scripts (SC2034), and runtime
# globals like root_device are assigned by sourcing scripts (SC2154).
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154

kblayout=us
locale=en_US.UTF-8

BTRFS_MOUNT_OPTIONS="noatime,compress=zstd:3"
EFI_MOUNT_OPTIONS="fmask=0137,dmask=0027,nodev,nosuid,noexec"
RESCUE_UKI_TARGET=/efi/EFI/Linux/arch-rescue.efi

# One row per subvolume: name, mountpoint, mount options added to
# BTRFS_MOUNT_OPTIONS (- for none), and what rescue reinstall does with it:
#   recreate  deleted and created empty; @ itself is renamed aside and kept
#             until the reinstall succeeds
#   keep      always survives; these are what make reinstall possible without
#             Secure Boot Setup Mode or re-enrollment
#   ask       the user chooses whether to preserve or erase it
BTRFS_LAYOUT=(
    "@            /                    -                    recreate"
    "@snapshots   /.snapshots          nodev,nosuid,noexec  recreate"
    "@home        /home                nodev,nosuid         ask"
    "@root        /root                nodev,nosuid         recreate"
    "@var_log     /var/log             nodev,nosuid,noexec  recreate"
    "@var_cache   /var/cache           nodev,nosuid,noexec  recreate"
    "@var_tmp     /var/tmp             nodev,nosuid         recreate"
    "@docker      /var/lib/docker      -                    recreate"
    "@containerd  /var/lib/containerd  -                    recreate"
    "@containers  /var/lib/containers  -                    recreate"
    "@machines    /var/lib/machines    -                    recreate"
    "@portables   /var/lib/portables   -                    recreate"
    "@flatpak     /var/lib/flatpak     -                    recreate"
    "@libvirt     /var/lib/libvirt     -                    recreate"
    "@sbctl       /var/lib/sbctl       nodev,nosuid,noexec  keep"
    "@iwd         /var/lib/iwd         nodev,nosuid,noexec  keep"
    "@tailscale   /var/lib/tailscale   nodev,nosuid,noexec  keep"
    "@netbird     /var/lib/netbird     nodev,nosuid,noexec  keep"
    "@srv         /srv                 nodev,nosuid         recreate"
)

# Prints the subvolume names whose reinstall policy is one of the arguments.
layout_subvolumes() {
    local row subvolume mountpoint options policy

    for row in "${BTRFS_LAYOUT[@]}"; do
        read -r subvolume mountpoint options policy <<<"$row"
        if [[ " $* " == *" $policy "* ]]; then
            printf '%s\n' "$subvolume"
        fi
    done
}

have_network() {
    curl --silent --max-time 5 https://archlinux.org >/dev/null 2>&1
}

show_wifi_instructions() {
    local resume_command=$1

    printf '\nWi-Fi connection instructions (run these from the shell):\n'
    printf '  1. Run: iwctl\n'
    printf '  2. Run: device list\n'
    printf '     Replace wlan0 below with the wireless device shown in the list.\n'
    printf '  3. Run: station wlan0 scan\n'
    printf '  4. Run: station wlan0 get-networks\n'
    printf '  5. Run: station wlan0 connect "Your Wi-Fi name"\n'
    printf '     Use your network name and enter the Wi-Fi password when prompted.\n'
    printf '  6. Run: exit (to leave iwctl)\n'
    printf '  7. Wait a few seconds, then run: %s\n' "$resume_command"
    printf '     Internet access will be checked again.\n\n'
}

# Prompts shared by fresh install and rescue reinstall.
prompt_system_settings() {
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

target_chroot() {
    arch-chroot /mnt "$@"
}

# Each settings/<subsystem>/ directory is a partial root filesystem. Files are
# installed 0644, or 0755 when executable, whatever the checkout's umask was.
install_settings_tree() {
    local tree=$1 source mode

    while IFS= read -r -d '' source; do
        mode=0644
        [[ -x "$source" ]] && mode=0755
        install -D -m "$mode" "$source" "/mnt${source#"$tree"}"
    done < <(find "$tree" -type f -print0)
}

install_user_settings() {
    local user_home="/mnt/home/$username"
    local user_uid user_gid directory config

    user_uid=$(target_chroot id -u "$username")
    user_gid=$(target_chroot id -g "$username")

    for directory in .config .config/niri .config/mango; do
        if [[ ! -d "$user_home/$directory" ]]; then
            install -d -m 0755 -o "$user_uid" -g "$user_gid" "$user_home/$directory"
        fi
    done

    for config in .config/niri/config.kdl .config/mango/config.conf; do
        # Keep existing user configuration when rescue reinstall preserves home,
        # including symlinks whose targets may currently be unavailable.
        if [[ ! -e "$user_home/$config" && ! -L "$user_home/$config" ]]; then
            install -m 0644 -o "$user_uid" -g "$user_gid" \
                "$SETTINGS_DIR/user/$config" "$user_home/$config"
        fi
    done
}

collect_selected_packages() {
    mapfile -t selected_packages < <(awk 'NF && $1 !~ /^#/ { print $1 }' "$SCRIPT_DIR"/packages/*.conf | sort -u)
    if (( ${#selected_packages[@]} == 0 )); then
        show_error "No packages found in $SCRIPT_DIR/packages"
        exit 1
    fi
}

preflight_validate_packages() {
    local packages=("${selected_packages[@]}" snap-pac)

    show_info "Validating ${#packages[@]} package names from $SCRIPT_DIR/packages plus deferred snap-pac"
    if ! pacman -Sp --print-format '%n' "${packages[@]}" >/dev/null; then
        show_error "Unresolvable package names found. Fix the package files and re-run."
        exit 1
    fi
}

# Signs in place, or to a separate output file when one is given. -s records
# the file in sbctl's database so the sbctl pacman hook re-signs it later.
sign_target_file() {
    target_chroot sbctl sign -s ${2:+-o "$2"} "$1"
}

mount_target_layout() {
    local row subvolume mountpoint options policy

    # @ is the first row, so / is mounted before the mountpoints inside it.
    for row in "${BTRFS_LAYOUT[@]}"; do
        read -r subvolume mountpoint options policy <<<"$row"
        [[ "$options" == - ]] && options=
        install -d -m 0755 "/mnt${mountpoint%/}"
        mount -o "$BTRFS_MOUNT_OPTIONS${options:+,$options},subvol=$subvolume" "$root_device" "/mnt${mountpoint%/}"
    done
    chmod 0700 /mnt/root
    chmod 1777 /mnt/var/tmp
    install -d -m 0755 /mnt/efi
    mount -o "$EFI_MOUNT_OPTIONS" "$efi_part" /mnt/efi
}

setup_snapper() {
    show_info "Configuring Snapper"

    # The same result as `snapper create-config /`, without the nested
    # .snapshots subvolume it would create: @snapshots is already mounted there.
    install -m 0640 /mnt/usr/share/snapper/config-templates/default /mnt/etc/snapper/configs/root
    sed -Ei 's/^(TIMELINE_CREATE|TIMELINE_CLEANUP|NUMBER_CLEANUP|EMPTY_PRE_POST_CLEANUP)=.*/\1="no"/' \
        /mnt/etc/snapper/configs/root
    sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root"/' /mnt/etc/conf.d/snapper
    chmod 0750 /mnt/.snapshots

    # Install snap-pac only after Snapper's root config is in place, so
    # installer pacman work is not captured.
    target_chroot pacman -S --needed --noconfirm snap-pac
}

# Installs and configures the OS into the mounted target layout. Shared by
# fresh install and rescue reinstall, so both paths build the same system.
install_target_system() {
    show_section "Base System"
    show_info "Installing the base system and ${#selected_packages[@]} packages with pacstrap"
    # Both microcode packages are installed; mkinitcpio's microcode hook
    # embeds only the one that matches the CPU.
    pacstrap -K /mnt \
        base base-devel linux linux-headers linux-firmware intel-ucode amd-ucode \
        "${selected_packages[@]}"

    show_info "Generating fstab"
    genfstab -U /mnt >/mnt/etc/fstab

    root_uuid=$(blkid -s UUID -o value "$root_part")

    show_section "System Configuration"
    show_info "Configuring target system"
    configure_target_system
}

# The fresh-install-only steps (rescue UKI copy, LUKS token enrollment, Secure
# Boot key creation/enrollment) stay in install.bash.
configure_target_system() {
    local tree profile crypt_options

    printf '%s\n' "$hostname" >/mnt/etc/hostname
    sed -i "/^#$locale/s/^#//" /mnt/etc/locale.gen
    printf 'LANG=%s\n' "$locale" >/mnt/etc/locale.conf
    printf 'KEYMAP=%s\n' "$kblayout" >/mnt/etc/vconsole.conf
    ln -sf "/usr/share/zoneinfo/$timezone" /mnt/etc/localtime
    target_chroot hwclock --systohc || show_warn "hwclock --systohc failed; set the hardware clock manually after install"
    target_chroot locale-gen >/dev/null

    # settings/user is installed per user below; settings/optional holds the
    # files that depend on an installer prompt.
    for tree in "$SETTINGS_DIR"/*/; do
        case "$tree" in
            */optional/ | */user/) ;;
            *) install_settings_tree "${tree%/}" ;;
        esac
    done
    if [[ "$disable_bluetooth" == "yes" ]]; then
        install -m 0644 "$SETTINGS_DIR/optional/etc/modprobe.d/disable-bluetooth.conf" /mnt/etc/modprobe.d/
    fi
    if [[ "$disable_thunderbolt" == "yes" ]]; then
        install -m 0644 "$SETTINGS_DIR/optional/etc/modprobe.d/disable-thunderbolt.conf" /mnt/etc/modprobe.d/
    fi
    chmod 0440 /mnt/etc/sudoers.d/wheel
    install -d -m 0755 /mnt/etc/apparmor/earlypolicy

    for profile in /mnt/usr/local/share/firewall-profiles/*.nft; do
        target_chroot nft --check --file "${profile#/mnt}"
    done
    install -m 0644 /mnt/usr/local/share/firewall-profiles/drop.nft /mnt/etc/nftables.conf

    systemctl --root=/mnt --quiet enable \
        iwd.service systemd-networkd.service systemd-networkd-wait-online.service \
        systemd-resolved.service systemd-timesyncd.service nftables.service \
        apparmor.service auditd.service tailscaled.service pcscd.service \
        fstrim.timer systemd-boot-update.service

    sed -Ei 's/^#(Color)$/\1\nILoveCandy/;s/^#(ParallelDownloads).*/\1 = 10/' /mnt/etc/pacman.conf

    case "$unlock_method" in
        tpm2) crypt_options="tpm2-device=auto,x-systemd.device-timeout=0" ;;
        fido2) crypt_options="fido2-device=auto,x-systemd.device-timeout=30" ;;
        passphrase) crypt_options="x-systemd.device-timeout=0" ;;
    esac
    printf 'cryptroot  UUID=%s  none  %s,password-echo=no,timeout=0,no-read-workqueue,no-write-workqueue,discard\n' \
        "$root_uuid" "$crypt_options" >/mnt/etc/crypttab.initramfs

    # Drop initramfs images generated by the stock presets during pacstrap;
    # nothing references them once the UKI presets take over.
    rm -f /mnt/boot/initramfs-*.img

    target_chroot mkinitcpio -P

    if ! target_chroot id -u "$username" &>/dev/null; then
        target_chroot useradd -m -G users,wheel -s /bin/bash "$username"
    else
        target_chroot usermod -aG users,wheel "$username"
    fi

    install_user_settings

    printf '%s:%s\n' "$username" "$userpass" | target_chroot chpasswd

    setup_snapper
    target_chroot passwd -l root >/dev/null
}

install_and_sign_boot_manager() {
    # Sign the systemd-boot source first: bootctl copies the .efi.signed
    # file to the ESP when one exists, and future systemd updates re-sign it
    # via the sbctl pacman hook before systemd-boot-update copies it.
    sign_target_file /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
        /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed

    target_chroot bootctl --esp-path=/efi --variables=no install

    sign_target_file /efi/EFI/Linux/arch-linux.efi
    if [[ -f "/mnt$RESCUE_UKI_TARGET" ]]; then
        sign_target_file "$RESCUE_UKI_TARGET"
    fi

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
}

finalize_target_dns() {
    # Deferred to the end: the chroot steps above need working DNS, which the
    # live environment provides by bind-mounting its resolv.conf over a
    # regular file. Only now hand resolution over to systemd-resolved.
    ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
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
