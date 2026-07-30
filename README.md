# Arch New Installer

Personal Arch Linux installer for a UEFI laptop/desktop setup built around Btrfs, direct UKI boot, Snapper rollback, and an on-disk rescue UKI.

The supported install path is the custom ISO built by this repository. Do not use a stock Arch ISO clone-and-run workflow for normal installs; the installer expects the generated rescue UKI artifact to be present inside the custom ISO.

## 0. Design Overview

This installer creates one Arch Linux system with:

- UEFI boot only.
- Btrfs root filesystem with sibling subvolumes.
- One installed kernel: `linux`.
- Unified Kernel Images booted directly by firmware through EFISTUB.
- No `systemd-boot`, GRUB, or other bootloader.
- Mandatory LUKS root encryption with selectable passphrase-only, TPM2 + PIN, or FIDO2 + PIN unlock.
- Mandatory Secure Boot setup with `sbctl`.
- Mandatory kernel lockdown in integrity mode.
- Snapper root snapshots with `snap-pac` pre/post pacman snapshots.
- No automatic Snapper cleanup. Snapshots stay until you delete them.
- A rescue UKI installed on the target ESP for rollback/repair without USB media.

EFI files and firmware boot entries intentionally use the same names:

```text
EFI file                         EFI boot entry
/efi/EFI/Linux/arch-linux.efi     arch-linux
/efi/EFI/Linux/arch-rescue.efi    arch-rescue
```

User-facing commands:

```text
install-arch    run the installer from the custom ISO
rollback-root   rollback a pacman transaction from the installed system
rescue-root     repair or replace the root subvolume from rescue media
```

Build/install flow:

```text
sudo ./iso/build.sh
    -> builds artifacts/arch-rescue.efi
    -> embeds this repo and the rescue UKI into a custom ISO

boot custom ISO
    -> run install-arch
    -> installer copies arch-rescue.efi to the target ESP
    -> installer creates arch-linux and arch-rescue firmware entries
```

Secure Boot model:

- Firmware must already be in Secure Boot Setup Mode before the installer runs.
- The installer creates `sbctl` keys, enrolls them, signs `arch-linux.efi`, signs `arch-rescue.efi`, and verifies signatures.
- `fwupd` is configured for custom Secure Boot keys with `/usr/lib/fwupd/efi/fwupdx64.efi.signed` and `DisableShimForSecureBoot=true`.
- Secure Boot private keys remain on the installed system under `/var/lib/sbctl`, which is mounted from the `@sbctl` Btrfs subvolume.
- The rescue UKI is not signed at ISO build time. It is signed during installation with the target system's keys.

## 1. Build

Build on an Arch Linux machine from the repository root:

```bash
sudo ./iso/build.sh
```

Faster builds:

- The build uses the build machine's pacman cache, normally `/var/cache/pacman/pkg/`.
- Update the build machine before building for fresher package databases, fewer mirror/version mismatches, and better cache reuse:

```bash
sudo pacman -Syu
sudo ./iso/build.sh
```

- Do not clear the pacman cache before building unless you intentionally want a cold rebuild. Clearing the cache forces packages to download again and makes the build slower.

The build script does all required build work. There is no separate required rescue UKI build command.

What the build does:

1. Installs build dependencies if needed: `archiso`, `rsync`, `mkosi`, `openssl`, and `git`.
2. Prompts for a rescue root password.
3. Hashes that password into a temporary `rescue-uki/mkosi.rootpw` file.
4. Copies the live rescue command into the mkosi overlay as `rescue-root`.
5. Builds the rescue UKI with mkosi.
6. Writes the rescue UKI artifact to `artifacts/arch-rescue.efi`.
7. Deletes the temporary password file and copied overlay command on exit.
8. Builds the custom ISO from the Arch `releng` archiso profile.
9. Copies the current repository into the ISO at `/root/arch-new-install`.
10. Explicitly embeds `artifacts/arch-rescue.efi` into the ISO.
11. Removes intermediate rescue UKI and mkosi outputs after the ISO is built.

Build outputs:

```text
artifacts/arch-rescue.efi         generated rescue UKI intermediate, removed after successful ISO build
iso/out/arch-btrfs-*.iso          final generated installer ISO, gitignored
```

The ISO contains these launcher commands:

```text
install-arch
rescue-root
```

Rebuild the ISO when:

- Installer code changes.
- Rescue behavior changes.
- You want a newer rescue UKI kernel/package set.
- The live ISO pacman keyring is old.

## 2. Install

Boot the generated custom ISO, then run:

```bash
install-arch
```

The selected target disk is destroyed. Read every prompt carefully.

The installer checks internet access before disk work starts. If the system is offline, it opens the `impala` Wi-Fi TUI. Wi-Fi credentials joined in the live environment are copied into the installed system so first boot can reconnect.

Fixed security policy:

- LUKS root encryption is always enabled.
- Secure Boot setup is always required.
- Kernel lockdown is always enabled with `lockdown=integrity`.

Installer prompts:

- LUKS unlock method: passphrase-only, TPM2 + PIN, or FIDO2 + PIN.
- Disable Bluetooth: yes/no.
- Disable Thunderbolt: yes/no.
- Hostname.
- Timezone.
- User account and password.
- Target disk.
- Optional `blkdiscard` secure wipe for SSD/NVMe devices.

LUKS unlock behavior:

- Passphrase-only installs keep the passphrase unlock method.
- TPM2 + PIN and FIDO2 + PIN installs use the install user's password only as a temporary enrollment passphrase, then remove that password slot. Add backup unlock methods later with `systemd-cryptenroll` if you want them.

Secure Boot requirement:

- Firmware must be in Secure Boot Setup Mode before running the installer.
- If Setup Mode is not enabled, the installer stops before destructive disk work.

Disk layout:

```text
Partition  Size       Type          Filesystem          Mount
1          2 GiB      EFI System    FAT32               /efi
2          remainder  Linux root    Btrfs or LUKS+Btrfs /
```

The installer recreates the ESP with:

```bash
mkfs.fat -F 32 -n EFI
```

Btrfs subvolumes:

```text
Subvolume     Mount
@             /
@snapshots    /.snapshots
@home         /home
@root         /root
@var_log      /var/log
@var_cache    /var/cache
@var_tmp      /var/tmp
@docker       /var/lib/docker
@containerd   /var/lib/containerd
@containers   /var/lib/containers
@machines     /var/lib/machines
@flatpak      /var/lib/flatpak
@libvirt      /var/lib/libvirt
@sbctl        /var/lib/sbctl
@iwd          /var/lib/iwd
@tailscale    /var/lib/tailscale
@netbird      /var/lib/netbird
@srv          /srv
```

Only `@` is managed by Snapper. `/var/lib/pacman` remains inside `@`, so package database changes are part of root rollback.

The Docker/container subvolumes are created even though Docker packages are not installed by this installer. They make the storage boundary explicit: future container images, layers, and writable state under `/var/lib/docker`, `/var/lib/containerd`, and `/var/lib/containers` stay outside root snapshots.

Installed boot files:

```text
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
```

Installed firmware boot entries:

```text
arch-linux
arch-rescue
```

Package customization:

```text
packages/base.conf                  base CLI, network, security, backup, utility packages
packages/desktop-base.conf          desktop common packages, fonts, audio, browser, firmware tools
packages/desktop-niri.conf          Niri compositor/session packages
packages/desktop-driver-intel.conf  Intel GPU packages, installed when Intel graphics are detected
packages/desktop-driver-amd.conf    AMD GPU packages, installed when AMD graphics are detected
```

Each package file is plain text. One package per line. Blank lines and lines beginning with `#` are ignored. Package names are validated before destructive disk work starts.

Settings customization:

```text
settings/access/       sudo and polkit policy
settings/boot/         kernel command line, mkinitcpio config, UKI preset
settings/hardware/     Bluetooth, Thunderbolt, Wi-Fi, and fwupd configuration
settings/network/      networkd, resolved, iwd, and network sysctls
settings/power/        sleep, watchdog, and zram policy
settings/rollback/     rollback-root helper
settings/security/     AppArmor, coredumps, kernel sysctls, and module policy
```

Each `settings/<subsystem>/` directory is a partial root filesystem. For example:

```text
settings/rollback/usr/local/sbin/rollback-root
```

installs to:

```text
/usr/local/sbin/rollback-root
```

## 3. Rollback

Normal rollback happens from the installed system with:

```bash
sudo rollback-root
```

Direct form:

```bash
sudo rollback-root PRE POST
```

What `rollback-root` does:

1. Lists recent Snapper pre/post pairs created by `snap-pac`.
2. Shows `snapper status PRE..POST` for the selected pair.
3. Asks for confirmation.
4. Runs `snapper -c root undochange PRE..POST`.
5. Rebuilds UKIs with `mkinitcpio -P`.
6. Signs and verifies UKIs when `sbctl` keys exist.
7. Offers to reboot.

What it does not do:

- It does not create safety snapshots.
- It does not maintain rollback journals.
- It does not automatically delete snapshots.

Snapper configuration created by the installer:

```text
TIMELINE_CREATE=no
TIMELINE_CLEANUP=no
NUMBER_CLEANUP=no
EMPTY_PRE_POST_CLEANUP=no
```

Snapshots are retained until you manually delete them.

Delete one snapshot:

```bash
sudo snapper -c root delete SNAPSHOT_NUMBER
```

Delete a pre/post pair:

```bash
sudo snapper -c root delete PRE_NUMBER POST_NUMBER
```

## 4. Rescue

Use rescue when the installed system cannot boot normally, cannot be unlocked normally, or needs root filesystem repair from outside the running system.

If the installed system still boots, prefer `rollback-root` first. It is narrower: it reverts one selected pacman pre/post pair from inside the running system.

Use `rescue-root` when you need an offline repair environment or when the running system is too broken to trust.

Rescue entry points:

```text
firmware -> arch-rescue
custom ISO -> rescue-root
```

The installed `arch-rescue` firmware entry boots:

```text
/efi/EFI/Linux/arch-rescue.efi
```

The custom ISO also provides:

```bash
rescue-root
```

`rescue-root` is a guided Bash command with two actions:

```text
Mount installation and enter a repair shell
Replace @ from a Snapper snapshot
```

It assumes the disk layout created by this installer:

```text
partition 1 -> ESP
partition 2 -> root, either Btrfs or LUKS+Btrfs
```

It refuses to continue if `/mnt` is already mounted or `/dev/mapper/cryptroot` already exists, because that usually means a previous rescue attempt was not cleaned up.

### Choose Manual Repair

Choose manual repair when you need to inspect or fix a specific problem and you do not want to replace the whole root subvolume.

Good uses for manual repair:

- Fix a bad config file.
- Inspect logs from the broken system.
- Rebuild the installed UKI manually.
- Reinstall or remove packages from a chroot.
- Fix `/etc/fstab`, `/etc/crypttab.initramfs`, or `/etc/cmdline.d/*`.
- Fix Secure Boot signatures with `sbctl`.
- Copy files off the system before doing anything more destructive.

Do not choose manual repair if your actual goal is to return the entire root filesystem to a known-good Snapper snapshot. Use root replacement for that.

Manual repair does this:

1. Select the installed disk.
2. Treat partition 1 as the ESP and partition 2 as root.
3. Unlock LUKS if present.
4. Mount the installed `@` root subvolume at `/mnt`.
5. Mount the ESP at `/mnt/efi` when `/mnt/efi` exists.
6. Print chroot and cleanup instructions.

It does not automatically enter the chroot. You choose when to enter it.

Enter the installed system:

```bash
arch-chroot /mnt
```

Inside the chroot, mount the remaining fstab entries if needed:

```bash
mount -a
```

Common commands inside the chroot:

```bash
mkinitcpio -P
sbctl sign -s /efi/EFI/Linux/arch-linux.efi
sbctl sign -s /efi/EFI/Linux/arch-rescue.efi
sbctl verify
```

When finished, exit the chroot and unmount manually:

```bash
exit
umount -R /mnt
```

If LUKS was opened, close it after unmounting:

```bash
cryptsetup close cryptroot
```

### Choose Root Replacement

Choose root replacement when the installed system is badly broken and you want to replace the current `@` root subvolume with a previous Snapper snapshot.

Good uses for root replacement:

- A system update made the machine unbootable.
- A configuration change broke early boot or login.
- The normal `rollback-root` path is unavailable because the system does not boot.
- You want the entire root filesystem back at the selected snapshot state.

Do not choose root replacement for a small targeted fix. Use manual repair when you only need to edit a file, rebuild UKIs, inspect logs, or copy data.

Root replacement affects the `@` subvolume only. It does not roll back sibling subvolumes such as `@home`, `@iwd`, `@sbctl`, `@tailscale`, `@netbird`, `@flatpak`, or `@libvirt`.

Root replacement does this:

1. Select the installed disk.
2. Treat partition 1 as the ESP and partition 2 as root.
3. Unlock LUKS if present.
4. Mount the Btrfs top-level volume at `/mnt`.
5. List snapshots from `@snapshots`.
6. Ask which snapshot should become the new `@`.
7. Create a temporary replacement root named `@new-rollback-<timestamp>`.
8. Move the current `@` to `@old-<timestamp>`.
9. Move the temporary replacement into place as the new `@`.
10. Set the Btrfs default subvolume to the new `@`.
11. Unmount the top-level volume and mount the restored `@` at `/mnt`.
12. Rebuild UKIs with `mkinitcpio -P`.
13. Sign and verify UKIs when `sbctl` keys exist.
14. Unmount everything and close LUKS if it was opened.
15. Offer to reboot.

The old root is intentionally kept:

```text
@old-<timestamp>
```

This gives you a manual fallback if the selected snapshot was wrong. Delete `@old-<timestamp>` only after confirming the restored system boots and contains what you expect.

To delete the old root later, boot a working system or rescue environment, mount the Btrfs top-level volume, delete the old root, then unmount:

```bash
mount -o subvolid=5 ROOT_DEVICE /mnt
btrfs subvolume delete /mnt/@old-<timestamp>
umount /mnt
```

Replace `ROOT_DEVICE` with the unlocked root device, for example `/dev/mapper/cryptroot` for LUKS or the root partition for an unencrypted install.

## 5. Reference

Important paths:

```text
install.bash                                      main installer
iso/build.sh                                      custom ISO build script
iso/out/                                          generated ISO output, gitignored
artifacts/arch-rescue.efi                         generated rescue UKI intermediate, removed after successful ISO build
iso/airootfs/usr/local/bin/install-arch           live ISO installer launcher
iso/airootfs/usr/local/bin/rescue-root            live ISO rescue launcher
settings/rollback/usr/local/sbin/rollback-root    installed rollback helper
rescue-uki/                                       mkosi rescue UKI definition
```

Boot-related installed paths:

```text
/etc/cmdline.d/defaults.conf
/etc/cmdline.d/security.conf
/etc/cmdline.d/iommu.conf
/etc/cmdline.d/filesystem.conf
/etc/cmdline.d/intel.conf          installed on non-AMD CPUs
/etc/cmdline.d/lockdown.conf       always installed for lockdown=integrity
/etc/cmdline.d/root.conf           generated during install
/etc/mkinitcpio.conf               installed from encrypted variant
/etc/mkinitcpio.d/linux.preset
/etc/fwupd/fwupd.conf              configured for custom Secure Boot keys
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
```

`iso/build.sh` clears old ISO outputs before each build, then removes rescue UKI and mkosi intermediate outputs after a successful build. The new final ISO remains under `iso/out/`.
