# Arch New Installer

Personal Arch Linux installer for a UEFI laptop/desktop setup built around Btrfs, systemd-boot with signed UKIs, Snapper rollback, and an on-disk rescue UKI.

The supported install path is the custom ISO built by this repository. Do not use a stock Arch ISO clone-and-run workflow for normal installs; the installer expects the generated rescue UKI artifact to be present inside the custom ISO.

## 0. Design Overview

This installer creates one Arch Linux system with:

- UEFI boot only.
- Btrfs root filesystem with sibling subvolumes.
- One installed kernel: `linux`.
- Unified Kernel Images (Type #2) booted through a signed `systemd-boot` boot menu.
- No GRUB, shim, or Type #1 loader entries.
- Mandatory LUKS root encryption with selectable passphrase-only, TPM2 + PIN, or FIDO2 + PIN unlock.
- Mandatory Secure Boot setup with `sbctl`.
- Mandatory kernel lockdown in integrity mode.
- Default-deny nftables host firewall with selectable persistent profiles.
- Snapper root snapshots with `snap-pac` pre/post pacman snapshots.
- No scheduled Snapper cleanup. Snapshots stay until you delete them.
- A rescue UKI installed on the target ESP for rollback/repair without USB media.

The boot chain is:

```text
firmware -> signed systemd-boot -> signed arch-linux.efi (default)
                                -> signed arch-rescue.efi (menu entry)
```

`systemd-boot` auto-discovers the UKIs in `/efi/EFI/Linux/`; there are no loader entry files. The rescue UKI is displayed as `Arch Rescue`. The firmware gets a single boot entry named `Linux Boot Manager`.

User-facing commands:

```text
install-arch      run the installer from the custom ISO
firewall-profile  select the persistent nftables firewall profile
rescue-root       repair, restore, or reinstall the OS from rescue media
```

Build/install flow:

```text
sudo ./iso/build.sh
    -> builds artifacts/arch-rescue.efi
    -> embeds this repo and the rescue UKI into a custom ISO

boot custom ISO
    -> run install-arch
    -> installer copies arch-rescue.efi to the target ESP
    -> installer installs signed systemd-boot and creates the Linux Boot Manager firmware entry
```

Secure Boot model:

- Firmware must already be in Secure Boot Setup Mode before the installer runs.
- The installer creates `sbctl` keys, enrolls them, and signs the `systemd-bootx64.efi` source (which `bootctl` copies to the ESP), `arch-linux.efi`, and `arch-rescue.efi`. A failed signature stops the install.
- `fwupd` is configured for custom Secure Boot keys with `/usr/lib/fwupd/efi/fwupdx64.efi.signed` and `DisableShimForSecureBoot=true`.
- Secure Boot private keys remain on the installed system under `/var/lib/sbctl`, which is mounted from the `@sbctl` Btrfs subvolume.
- The rescue UKI is not signed at ISO build time. It is signed during installation with the target system's keys.

## 1. Build

Build on an Arch Linux machine from the repository root:

```bash
sudo ./iso/build.sh
```

Package caches:

- The ISO build downloads into the build machine's normal pacman cache, `/var/cache/pacman/pkg/`, and reuses what is already there.
- The rescue UKI build uses mkosi's own package cache, `/var/cache/mkosi/` when run with `sudo`. It is separate from the host's pacman cache and databases, and it is kept between builds.
- Update the build machine before building for fresher package databases and fewer mirror/version mismatches:

```bash
sudo pacman -Syu
sudo ./iso/build.sh
```

- Each build starts with fresh image roots. Temporary rescue output and workspaces are kept under `/var/tmp/` and removed on exit. Unpacked image roots and the final ISO still need additional disk space while building.

The build script does all required build work. There is no separate required rescue UKI build command.

What the build does:

1. Installs its build dependencies with `pacman -S --needed --noconfirm`: `archiso`, `rsync`, and `git` for the ISO, and `mkosi`, `python-pefile`, `openssl`, `systemd-ukify`, `kmod`, `libarchive`, `cpio`, and `zstd` for the rescue UKI. pacman skips packages already installed and current.
2. Prompts for a rescue root password.
3. Hashes that password into a temporary `rescue-uki/mkosi.rootpw` file.
4. Builds the rescue UKI with the `mkosi` package from the Arch repositories. `rescue-uki/mkosi.conf` copies `rescue-root` and the reinstall payload (package lists, settings, `installer-common.bash`) into the image straight from the repository. Build history and incremental image caching are disabled for a fresh image root each time.
5. Writes the rescue UKI artifact to `artifacts/arch-rescue.efi`.
6. Deletes the temporary password file on exit.
7. Builds the custom ISO from the Arch `releng` archiso profile.
8. Copies the current repository into the ISO at `/root/arch-new-install`.
9. Explicitly embeds `artifacts/arch-rescue.efi` into the ISO.
10. Removes the intermediate `artifacts/` directory after the ISO is built.

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

The installer checks internet access before disk work starts. If offline, it displays numbered `iwctl` instructions and returns to the shell. Connect using the steps below, then run `install-arch` again to re-check internet access and continue. For Ethernet, plug in the cable and run `install-arch` again.

1. Run `iwctl` from the live shell.
2. Run `device list`. Replace `wlan0` in the following commands with your wireless device.
3. Run `station wlan0 scan`.
4. Run `station wlan0 get-networks`.
5. Run `station wlan0 connect "Your Wi-Fi name"`, using your network name. Enter the Wi-Fi password when prompted.
6. Run `exit` to leave iwctl.
7. Wait a few seconds, then run `install-arch` again.

The installation ISO and rescue image use `iwctl` from the `iwd` package. The installed desktop system includes `impala`. Wi-Fi credentials from the live environment are not copied into the installed system; configure Wi-Fi after installation.

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
- Optional whole-device `blkdiscard` for SSD/NVMe devices. This is destructive but not guaranteed secure erasure.

LUKS unlock behavior:

- Passphrase-only installs keep the passphrase unlock method.
- TPM2 + PIN installs retain the initial LUKS passphrase alongside the TPM2 enrollment. When enrollment asks for the existing LUKS passphrase, enter the install user's password. Either that passphrase or the TPM2 PIN can unlock the drive afterwards, so a cleared or replaced TPM does not lock you out. Changing the account password later does not change the LUKS passphrase.
- FIDO2 + PIN installs retain the initial LUKS passphrase alongside the enrolled token. When enrollment asks for the existing LUKS passphrase, enter the install user's password. Either that passphrase or the YubiKey and its PIN can unlock the drive afterwards. Changing the account password later does not change the LUKS passphrase. See [Add a Backup FIDO2 Key](#add-a-backup-fido2-key) to enroll a second key using one USB port, test both keys, and optionally remove the password fallback.

Secure Boot requirement:

- Firmware must be in Secure Boot Setup Mode before running the installer.
- If Setup Mode is not enabled, the installer stops before destructive disk work.

Disk layout:

```text
Partition  Size       Type          Filesystem          Mount
1          2 GiB      EFI System    FAT32               /efi
2          remainder  Linux root    LUKS+Btrfs          /
```

The installer recreates the ESP with:

```bash
mkfs.fat -F 32 -n EFI
```

Btrfs subvolumes:

```text
Subvolume     Mount                    Extra mount options
@             /                        none
@snapshots    /.snapshots              nodev,nosuid,noexec
@home         /home                    nodev,nosuid
@root         /root                    nodev,nosuid
@var_log      /var/log                 nodev,nosuid,noexec
@var_cache    /var/cache               nodev,nosuid,noexec
@var_tmp      /var/tmp                 nodev,nosuid
@docker       /var/lib/docker          none
@containerd   /var/lib/containerd      none
@containers   /var/lib/containers      none
@machines     /var/lib/machines        none
@portables    /var/lib/portables       none
@flatpak      /var/lib/flatpak         none
@libvirt      /var/lib/libvirt         none
@sbctl        /var/lib/sbctl           nodev,nosuid,noexec
@iwd          /var/lib/iwd             nodev,nosuid,noexec
@tailscale    /var/lib/tailscale       nodev,nosuid,noexec
@netbird      /var/lib/netbird         nodev,nosuid,noexec
@srv          /srv                     nodev,nosuid
```

All Btrfs mounts use `noatime,compress=zstd:3`. The ESP is mounted at `/efi` with `fmask=0137,dmask=0027,nodev,nosuid,noexec`. Container, VM, machine, portable service, and Flatpak storage keep the base Btrfs options only for runtime compatibility.

Only `@` is managed by Snapper. `/var/lib/pacman` remains inside `@`, so package database changes are part of root rollback.

The Docker/container subvolumes are created even though Docker packages are not installed by this installer. They make the storage boundary explicit: future container images, layers, and writable state under `/var/lib/docker`, `/var/lib/containerd`, and `/var/lib/containers` stay outside root snapshots.

The `@machines` and `@portables` subvolumes prevent systemd-tmpfiles from creating nested subvolumes inside `@` at `/var/lib/machines` and `/var/lib/portables`.

Installed boot files:

```text
/efi/EFI/systemd/systemd-bootx64.efi
/efi/EFI/BOOT/BOOTX64.EFI
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
/efi/loader/loader.conf
```

Installed firmware boot entry:

```text
Linux Boot Manager
```

The `systemd-boot` menu defaults to `arch-linux.efi` and shows for 10 seconds so `arch-rescue.efi` stays one keypress away. To boot the rescue environment once from a running system, without changing the persistent default:

```bash
systemctl reboot --boot-loader-entry=arch-rescue.efi
```

Package customization:

```text
packages/base.conf                  base CLI, network, security, backup, utility packages
packages/desktop-base.conf          desktop common packages, fonts, audio, browser, firmware tools
packages/desktop-custom.conf        compositor/session/window-manager packages
packages/desktop-drivers.conf       Intel and AMD GPU packages, always installed
```

Every `packages/*.conf` file is installed; add a file to add a group. Each file is plain text, one package per line. Blank lines and lines beginning with `#` are ignored. Package names are validated before destructive disk work starts. Both `intel-ucode` and `amd-ucode` are installed with the base system; the initramfs embeds only the one that matches the CPU.

Settings customization:

```text
settings/access/       sudo and polkit policy
settings/boot/         kernel command line, mkinitcpio config, UKI preset
settings/hardware/     Wi-Fi and fwupd configuration
settings/network/      networkd, resolved, iwd, nftables, and network sysctls
settings/power/        sleep and zram policy
settings/security/     AppArmor, coredumps, kernel sysctls, and module policy
settings/optional/     files installed only when a prompt asks for them (Bluetooth and Thunderbolt blocks)
settings/user/         home-relative niri and mango configuration defaults
```

Each system `settings/<subsystem>/` directory is a partial root filesystem. For example:

```text
settings/network/usr/local/sbin/firewall-profile
```

installs to:

```text
/usr/local/sbin/firewall-profile
```

`settings/user/` is relative to the selected user's home directory. After creating
the account, the installer copies `.config/niri/config.kdl` and
`.config/mango/config.conf` into `/home/<username>/`, with user ownership and
permissions of `0644` for files and `0755` for newly created directories.
Existing configuration files and symlinks are kept, including during rescue
reinstallation with a preserved home directory.

### Add a Backup FIDO2 Key

After a FIDO2 installation, use the retained LUKS passphrase to enroll a backup key. Only the backup key needs to be connected during enrollment; the original key remains enrolled.

1. Identify the encrypted root partition:

   ```bash
   sudo cryptsetup status cryptroot
   ```

   Use the partition shown on the `device:` line, not `/dev/mapper/cryptroot`. Set a variable to that path for the commands below; `/dev/nvme0n1p2` is an example that must be replaced with your actual partition:

   ```bash
   luks_device=/dev/nvme0n1p2
   ```

2. Disconnect the original YubiKey and connect only the backup. The backup must support FIDO2 `hmac-secret` and the `eddsa` credential algorithm used by the installer, and have a FIDO2 PIN configured.

3. Enroll the backup without removing the password fallback:

   ```bash
   sudo systemd-cryptenroll "$luks_device" \
       --fido2-device=auto \
       --fido2-with-client-pin=yes \
       --fido2-with-user-presence=yes \
       --fido2-credential-algorithm=eddsa
   ```

   When asked for the current disk passphrase, enter the retained LUKS passphrase (the account password chosen during installation, unless the LUKS passphrase was changed separately). Follow the backup key's PIN and touch prompts.

4. List the enrolled slots:

   ```bash
   sudo systemd-cryptenroll "$luks_device"
   ```

   There should now be two `fido2` slots plus the retained `password` slot.

5. Reboot with only the backup key connected and verify that its PIN and touch unlock the drive. Then test another boot with only the original key connected. Keep the password fallback until both keys have been tested independently.

6. Optionally remove the password fallback after both boot tests succeed. In the new shell after reboot, set `luks_device` to the actual encrypted partition again, then run:

   ```bash
   sudo systemd-cryptenroll "$luks_device" --wipe-slot=password
   sudo systemd-cryptenroll "$luks_device"
   ```

   This removes all traditional LUKS password slots, leaving both FIDO2 enrollments intact. It does not change the user-account password. Without another enrolled recovery method, either YubiKey and its PIN is then required to unlock the drive, including from rescue.

The enrollments are stored in the LUKS header, outside Btrfs snapshots. Adding the backup or removing the password fallback does not require rebuilding or re-signing the UKI, and restoring a root snapshot does not undo these enrollment changes.

### Firewall

The installer enables `nftables.service` with the `drop` profile. It permits
outbound connections and required network control traffic while dropping new
inbound connections and all forwarding. The rules replace only the
installer-owned `inet workstation` table so independently managed tables,
including Tailscale's, are preserved.

Switch persistent profiles with:

```bash
firewall-profile
```

Available profiles:

```text
blackout  block all local IPv4 and IPv6 networking except loopback
drop      default workstation policy installed by the installer
general   add physical-LAN ping, multicast membership, and mDNS discovery
```

The `general` profile only permits discovery traffic. It does not install or
configure printing software and does not open an inbound IPP/CUPS port.

## 3. Rollback

`snap-pac` takes a Snapper pre/post snapshot pair around every pacman transaction. There are two ways to go back:

- **Undo one transaction from the running system** with `snapper undochange`, described here.
- **Replace the whole root with a snapshot** from the rescue environment. See [Choose Root Replacement](#choose-root-replacement). Use this when the system does not boot or when more than one transaction needs to go.

To undo a transaction, list the pairs, reverse the one you want, and rebuild the UKI:

```bash
sudo snapper -c root list --type pre-post
sudo snapper -c root undochange PRE..POST
sudo mkinitcpio -P
sudo systemctl reboot
```

`mkinitcpio -P` rebuilds the UKI from the reverted files, and the `sbctl` mkinitcpio hook signs it. Reboot before continuing to use the system so the running kernel and userspace match the reverted files. If pacman afterwards reports a stale lock and no pacman process is running, remove `/var/lib/pacman/db.lck`.

This is a file-level reversal, not a pacman-managed downgrade. `snapper undochange` reverses the filesystem difference recorded by the pair. It does not run package downgrade transactions or resolve package dependencies. Only files in the root Snapper configuration are affected; sibling subvolumes such as `@home`, `@var_log`, `@sbctl`, and the ESP are not rolled back. `/var/lib/pacman` is inside `@`, so its database changes are included.

Snapper configuration created by the installer:

```text
TIMELINE_CREATE=no
TIMELINE_CLEANUP=no
NUMBER_CLEANUP=no
EMPTY_PRE_POST_CLEANUP=no
```

All snapshots are retained until you manually delete them.

Delete one snapshot:

```bash
sudo snapper -c root delete SNAPSHOT_NUMBER
```

Delete a pre/post pair:

```bash
sudo snapper -c root delete PRE_NUMBER POST_NUMBER
```

## 4. Rescue

Use rescue when the installed system cannot boot normally or needs root filesystem repair from outside the running system.

If the installed system still boots and one pacman transaction caused the problem, prefer `snapper undochange` first (see [Rollback](#3-rollback)). It is narrower: it reverts a single pre/post pair from inside the running system.

Use `rescue-root` when you need an offline repair environment or when the running system is too broken to trust.

Rescue still requires a valid LUKS unlock method. It cannot bypass encryption. Passphrase-only installations can use their LUKS passphrase. FIDO2 and TPM2 installations can use the enrolled token and PIN or the retained initial LUKS passphrase, unless you removed that password slot yourself after installation. Enroll and test backup unlock methods before you need rescue.

Installed rescue UKI entry points:

```text
systemd-boot menu -> Arch Rescue
one-shot from a running system -> systemctl reboot --boot-loader-entry=arch-rescue.efi
```

Both installed entry points load the rescue UKI from:

```text
/efi/EFI/Linux/arch-rescue.efi
```

At its login prompt, log in as `root` with the rescue root password chosen when `sudo ./iso/build.sh` created the installer ISO, then run:

```bash
rescue-root
```

If the installed rescue UKI or ESP is unavailable, boot the generated custom ISO instead. The ISO boots its own Arch live environment; it does not load the target system's `/efi/EFI/Linux/arch-rescue.efi`. From the live shell, run `rescue-root`.

For Wi-Fi, follow the numbered `iwctl` connection instructions shown at login (also listed in [Install](#2-install)), then run `rescue-root`. If the reinstall action detects no internet access, it displays the same instructions and returns to the shell; connect, then run `rescue-root` and select the action again.

Both the on-disk rescue environment and custom ISO provide `rescue-root`, a guided Bash command with three actions:

```text
Repair installed system
Restore root from snapshot
Reinstall OS preserving selected state
```

It assumes the disk layout created by this installer:

```text
partition 1 -> ESP
partition 2 -> LUKS+Btrfs root
```

After selecting the disk, choose either token unlock for the enrolled TPM2/FIDO2 method or passphrase/recovery-key unlock for a retained or separately enrolled credential.

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
3. Unlock LUKS.
4. Mount the installed `@` root subvolume at `/mnt`.
5. Mount the ESP at `/mnt/efi` when `/mnt/efi` exists.
6. Attempt to mount the preserved `@sbctl` subvolume at `/mnt/var/lib/sbctl`.
7. Print chroot and cleanup instructions.

It mounts the root read-write and does not automatically enter the chroot. You choose when to enter it.

If `rescue-root` warns that the ESP or `@sbctl` could not be mounted, do not rebuild or sign UKIs until the mount problem is corrected. The installed Secure Boot keys are stored in `@sbctl`, outside the root snapshot.

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

Close LUKS after unmounting:

```bash
cryptsetup close cryptroot
```

### Choose Root Replacement

Choose root replacement when the installed system is badly broken and you want to replace the current `@` root subvolume with a previous Snapper snapshot.

Good uses for root replacement:

- A system update made the machine unbootable.
- A configuration change broke early boot or login.
- `snapper undochange` is unavailable because the system does not boot.
- You want the entire root filesystem back at the selected snapshot state.

Do not choose root replacement for a small targeted fix. Use manual repair when you only need to edit a file, rebuild UKIs, inspect logs, or copy data.

Root replacement affects the `@` subvolume only. It does not roll back sibling subvolumes such as `@home`, `@iwd`, `@sbctl`, `@tailscale`, `@netbird`, `@portables`, `@flatpak`, or `@libvirt`.

`rescue-root` lists every snapshot directory and description; it does not restrict the menu to pacman snapshots or identify the correct member of a pair for you. To reverse a failed `snap-pac` transaction, select the `pre` snapshot created immediately before that transaction, normally the lower-numbered member of its pre/post pair. The matching `post` snapshot represents the state after the transaction and normally reproduces the bad state. If the description and numbers do not make the intended state clear, cancel and inspect the snapshots before replacing `@`.

The selected snapshot must be able to rebuild its own boot image: it needs the `/efi` and `/var/lib/sbctl` mount-point directories and working `mkinitcpio` and `sbctl` commands, and the preserved `@sbctl` subvolume must contain the Secure Boot keys. If any of that is missing, the UKI rebuild fails and `rescue-root` stops before changing `@`.

Root replacement does this:

1. Select the installed disk.
2. Treat partition 1 as the ESP and partition 2 as root.
3. Unlock LUKS.
4. Mount the Btrfs top-level volume at `/mnt`.
5. List snapshots from `@snapshots`.
6. Ask which snapshot should become the new `@`.
7. Create a writable replacement root named `@new-<timestamp>` from the snapshot.
8. Mount the ESP and `@sbctl` inside the replacement, rebuild the UKI with `mkinitcpio -P`, and sign it.
9. Rename the current `@` to `@old-<timestamp>`, then rename the replacement to `@`.
10. Unmount everything and close LUKS.
11. Offer to reboot.

The selected source snapshot remains under `@snapshots`; root replacement does not delete it. After success, reboot to start the restored root and rebuilt UKI, then verify the system before deleting either the source snapshot or retained old root.

If the UKI rebuild fails, the replacement is deleted and `@` is left as it was. The rebuild may already have overwritten the UKI on the ESP, so the installed system might not boot until a UKI is rebuilt successfully. Stay in rescue and run `rescue-root` again: choose another snapshot, or choose **Repair installed system** and run `mkinitcpio -P` inside the chroot to rebuild the UKI for the current root.

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

For installations created by this installer, replace `ROOT_DEVICE` with the unlocked root device `/dev/mapper/cryptroot`.

### Choose Reinstall

Choose `Reinstall OS preserving selected state` when the operating system is beyond repair or beyond trust but the disk, encryption, and Secure Boot setup are intact. It rebuilds a fresh OS in place without repartitioning, without touching the LUKS container, and without firmware Secure Boot Setup Mode — the preserved `@sbctl` keys sign the new boot files.

Prefer the narrower tools when they fit: `snapper undochange` for one bad pacman transaction, root replacement for restoring a known-good snapshot, a full fresh install when the disk layout or encryption itself should change or the machine changes hands.

These subvolumes always survive reinstall:

```text
@sbctl @iwd @tailscale @netbird
```

`@home` is preserved by default. You may instead choose to erase it; that choice requires typing `ERASE` at its own confirmation and there is no retained copy — a chosen wipe means the data is actually gone. Every other subvolume (`@snapshots`, `@root`, `@var_log`, `@var_cache`, `@var_tmp`, container/VM storage, `@srv`) is deleted and recreated empty; previous Snapper snapshots are gone after reinstall. The current `@` is not deleted: it is renamed to `@old-reinstall-<timestamp>` and retained until you verify the reinstalled system, so a mid-reinstall failure (network loss during pacstrap, mirror outage) leaves the previous root intact and re-running the action is safe.

Reinstall does this:

1. Print the embedded payload version. The packages and settings used for reinstall are frozen into the rescue image at ISO build time; rebuilding the ISO refreshes them. Reinstalling from an old rescue image is a conscious choice.
2. Select the installed disk, treat partition 1 as ESP and partition 2 as LUKS root, and unlock it.
3. Verify the installer layout fingerprint: `@`, `@home`, and every always-preserved subvolume must exist, `@sbctl` must contain key material, and the ESP must mount. Anything else is not an installer-created system and the action refuses. Because the current root is retained, at least 16 GiB must be free on the Btrfs filesystem.
4. Check network reachability, refresh `archlinux-keyring` in the rescue environment, and validate all package names — all before anything destructive.
5. Ask the same questions as the fresh installer: Bluetooth/Thunderbolt toggles, hostname, timezone, username, and password. The LUKS boot unlock method is detected from the LUKS2 header (`systemd-tpm2`/`systemd-fido2` tokens, otherwise passphrase), never freely chosen: a wrong `crypttab.initramfs` on a token-only system is unbootable. No tokens are enrolled or wiped.
6. Show the effective preserve and recreate sets and the detected boot unlock method, and require confirmation.
7. Retire `@`, delete and recreate the recreate set (child subvolumes first), and mount the full target layout.
8. Run `pacstrap` with the payload package selection, generate `fstab`, and regenerate the target configuration with the same code as the fresh installer, including Snapper with deferred `snap-pac`.
9. Sign systemd-boot, the new UKI, the existing on-ESP rescue UKI, and `fwupd` with the preserved `@sbctl` keys, and recreate the `Linux Boot Manager` firmware entry.
10. Unmount, close LUKS, and offer to reboot.

The user account is recreated first, so it gets UID/GID 1000 like the fresh installer; with `@home` preserved, existing file ownership stays correct and ownership is verified after creation. SSH host keys are regenerated by the reinstall, so remote clients will show host-key-changed warnings on first connect; this is expected, not an attack.

If a reinstall fails partway, the installed system does not boot until a reinstall completes, because `@` is the unfinished new root. Run the action again once the cause (usually the network) is fixed. To go back to the previous root instead, put it back by hand from the rescue shell and rebuild its UKI:

```bash
cryptsetup open /dev/ROOT_PARTITION cryptroot   # if rescue-root closed it
mount -o subvolid=5 /dev/mapper/cryptroot /mnt
btrfs subvolume delete /mnt/@
mv /mnt/@old-reinstall-<timestamp> /mnt/@
umount /mnt
cryptsetup close cryptroot
```

Then run `rescue-root`, choose **Repair installed system**, and run `mkinitcpio -P` inside the chroot. The recreated subvolumes stay empty; only `@` and the preserved subvolumes come back.

Delete the retained old root only after verifying the reinstalled system, the same way as `@old-<timestamp>` above:

```bash
mount -o subvolid=5 /dev/mapper/cryptroot /mnt
btrfs subvolume delete /mnt/@old-reinstall-<timestamp>
umount /mnt
```

## 5. Maintenance

Maintain the installed desktop, installation media, and installed rescue image separately:

| Component | Normal workflow | Suggested timing |
| --- | --- | --- |
| Installed desktop | `sudo pacman -Syu` | Regular system updates |
| Installation ISO / recovery USB | Update the build host, run `sudo ./iso/build.sh`, boot-test, then refresh the USB | About monthly during active use; after installer changes; before a planned installation |
| Installed rescue UKI | Rebuild and re-sign it from the installed desktop (see below), then boot-test the replacement | Review about every three months; sooner after rescue fixes, relevant kernel/tool fixes, or hardware changes |

These intervals are recommendations, not expiration dates. Retain a tested recovery USB and the previous known-working ISO while validating replacements. A normal desktop package update does not refresh the contents of the installed rescue UKI. Rebuilding the ISO also does not replace the rescue image already installed on a machine.

### Refresh the Installed Rescue Image

Keep a complete checkout of this repository on the installed machine. From the working desktop, while internet access is available:

```bash
cd "$HOME/arch-install-btrfs"
git pull --ff-only
sudo pacman -Syu
```

If the desktop update requires a reboot, reboot now. Then build the rescue image and install it:

```bash
sudo ./rescue-uki/build.sh
sudo sbctl sign -o /efi/EFI/Linux/arch-rescue.efi artifacts/arch-rescue.efi
```

The builder asks you to choose and confirm the root password for the new rescue environment. Enter the old rescue password again if you want to retain it, or choose a new one. This does not change the desktop password or LUKS unlock credentials.

`sbctl sign -o` signs the freshly built image with this machine's existing keys and writes the signed result over the installed one. No new Secure Boot keys or firmware enrollment are needed. The new image includes updated packages and the checkout's rescue scripts, package lists, and reinstall settings.

The rescue image is not on the normal boot path. If a new image turns out to be bad, the desktop still boots and you can build and sign another one.

### Boot-Test the Replacement

Reboot into rescue when convenient:

```bash
sudo systemctl reboot --boot-loader-entry=arch-rescue.efi
```

1. Log in with the rescue root password selected during the build.
2. Check `uname -r` and the build identity in `/usr/lib/os-release` (`IMAGE_ID` and `IMAGE_VERSION`).
3. Confirm your disks are visible. If you rely on Wi-Fi, test connecting with `iwctl`.
4. Run `rescue-root` and select **Repair installed system** to test unlocking the drive and mounting the installed system. A routine boot test does not require a snapshot rollback or reinstall.
5. Follow the printed instructions to unmount `/mnt` and close `cryptroot` if it was opened, then reboot to the desktop.

If the replacement fails its boot test, boot the normal desktop, check out the previous known-good commit of this repository, and build and sign again. Keep a tested recovery USB available until the boot test passes.

### Refresh the Installation / Recovery USB

On your Arch build machine, update your checkout and the build host, then build:

```bash
git -C "$HOME/arch-install-btrfs" pull --ff-only
sudo pacman -Syu
sudo "$HOME/arch-install-btrfs/iso/build.sh"
```

Before building, copy any previous known-good ISO you want to retain to a location outside `iso/out/`; the build script clears that directory. Write the replacement ISO to your recovery USB using your usual flashing method, and test UEFI boot, networking, disk visibility, and the rescue repair action before relying on it.

During an actual snapshot rollback, use the tested rescue environment as built. Running `pacman -Syu` inside the live rescue environment only updates that temporary session and does not update the embedded UKI for the next boot. Rebuild and deploy the image from the desktop between recovery sessions instead.

## 6. Reference

Important paths:

```text
install.bash                                      main installer
installer-common.bash                             shared installer code, sourced by install.bash and the rescue reinstall action
ui.bash                                           shared terminal styling (colors, boxes, messages) for install.bash and rescue-root
iso/build.sh                                      custom ISO build script
iso/out/                                          generated ISO output, gitignored
artifacts/arch-rescue.efi                         generated rescue UKI intermediate, removed after successful ISO build
iso/airootfs/usr/local/bin/install-arch           live ISO installer launcher
iso/airootfs/usr/local/bin/rescue-root            live ISO rescue launcher
rescue-uki/                                       mkosi rescue UKI definition
/usr/local/share/arch-new-install                 reinstall payload inside the rescue UKI (packages, settings, shared code, payload-version)
/root/arch-new-install                            this repo embedded in the live ISO; doubles as the reinstall payload there
```

Boot-related installed paths:

```text
/etc/cmdline.d/defaults.conf
/etc/cmdline.d/security.conf
/etc/cmdline.d/iommu.conf
/etc/cmdline.d/filesystem.conf     root device, filesystem type, and @ subvolume
/etc/cmdline.d/lockdown.conf       always installed for lockdown=integrity
/etc/crypttab.initramfs            generated during install for the chosen unlock method
/etc/mkinitcpio.conf
/etc/mkinitcpio.d/linux.preset
/etc/fwupd/fwupd.conf              configured for custom Secure Boot keys
/efi/EFI/systemd/systemd-bootx64.efi
/efi/EFI/BOOT/BOOTX64.EFI
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
/efi/loader/loader.conf
/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed   signed source copy used by future systemd-boot updates
```

`iso/build.sh` clears old ISO outputs before each build, then removes the intermediate `artifacts/` directory after a successful build. The new final ISO remains under `iso/out/`.
