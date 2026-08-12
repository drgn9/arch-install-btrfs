# installer-common.bash - shared constants and helpers for the USB installer
# and the rescue reinstall path. Sourced, never executed.
# Constants defined here are used by sourcing scripts (SC2034), and runtime
# globals like root_device are assigned by sourcing scripts (SC2154).
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154

BTRFS_MOUNT_OPTIONS="noatime,compress=zstd:3"
BTRFS_DATA_MOUNT_OPTIONS="$BTRFS_MOUNT_OPTIONS,nodev,nosuid"
BTRFS_STRICT_MOUNT_OPTIONS="$BTRFS_DATA_MOUNT_OPTIONS,noexec"
EFI_MOUNT_OPTIONS="fmask=0137,dmask=0027,nodev,nosuid,noexec"
RESCUE_UKI_TARGET=/efi/EFI/Linux/arch-rescue.efi
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

# Plain sbctl verify exits 0 even for unsigned files, so enforce the
# signature from sbctl's JSON output. jq runs inside the target, matching
# rescue-root; the live/rescue environments do not ship jq.
verify_target_signed_file() {
    local file=$1 verification

    verification=$(target_chroot sbctl --json verify "$file")
    if ! target_chroot jq -e 'length == 1 and .[0].is_signed == 1' <<<"$verification" >/dev/null; then
        show_error "$file is not signed"
        return 1
    fi
}

sign_target_file() {
    local source=$1
    local output=${2:-$1}

    if [[ "$output" == "$source" ]]; then
        target_chroot sbctl sign -s "$source"
    else
        target_chroot sbctl sign -s -o "$output" "$source"
    fi
    verify_target_signed_file "$output"
}

mount_target_layout() {
    local subvolume_mount subvolume mountpoint mount_options

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

# Target configuration shared by fresh install and rescue reinstall. The
# fresh-install-only steps (rescue UKI copy, LUKS token enrollment, Secure
# Boot key creation/enrollment) stay in install.bash.
configure_target_system() {
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
}

install_and_sign_boot_manager() {
    # Sign the systemd-boot source first so bootctl copies an already
    # signed binary to the ESP, and so future systemd updates re-sign it
    # via the sbctl pacman hook before systemd-boot-update copies it.
    sign_target_file /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
        /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed

    target_chroot bootctl --esp-path=/efi --variables=no install

    sign_target_file /efi/EFI/systemd/systemd-bootx64.efi
    sign_target_file /efi/EFI/BOOT/BOOTX64.EFI
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
