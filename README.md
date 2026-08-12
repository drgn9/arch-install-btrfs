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
- No scheduled Snapper cleanup. Snapshots stay until you delete them or `rollback-root` successfully consumes a pre/post pair.
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
rollback-root     rollback a pacman transaction from the installed system
rescue-root       repair or replace the root subvolume from rescue media
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
- The installer creates `sbctl` keys, enrolls them, signs `systemd-bootx64.efi` (source, ESP copy, and fallback copy), signs `arch-linux.efi`, signs `arch-rescue.efi`, and verifies signatures.
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

1. Installs build dependencies if needed: `archiso`, `rsync`, `python`, `openssl`, and `git`.
2. Prompts for a rescue root password.
3. Hashes that password into a temporary `rescue-uki/mkosi.rootpw` file.
4. Copies `rescue-root` and `trusted-paccheck` into the mkosi overlay.
5. Builds the rescue UKI with mkosi. mkosi is pinned to version 26: it is downloaded once into `~/.cache/arch-new-install/mkosi/` (outside this repository) and reused on later builds, so behavior does not change when the build machine upgrades its own packages. Bump `MKOSI_VERSION` in `rescue-uki/build.sh` to upgrade mkosi deliberately.
6. Writes the rescue UKI artifact to `artifacts/arch-rescue.efi`.
7. Deletes the temporary password file and copied overlay commands on exit.
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
trusted-paccheck
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

The installer checks internet access before disk work starts. If the system is offline, it opens the `impala` Wi-Fi TUI. Wi-Fi credentials from the live environment are not copied into the installed system; configure Wi-Fi after installation.

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
- TPM2 + PIN and FIDO2 + PIN installs use the install user's password only as a temporary enrollment passphrase. When enrollment asks for the existing LUKS passphrase, enter the install user's password. The installer then removes that password slot. Add backup unlock methods later with `systemd-cryptenroll` if you want them.

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
settings/network/      networkd, resolved, iwd, nftables, and network sysctls
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

### Firewall

The installer enables `nftables.service` with the `drop` profile. It permits
outbound connections and required network control traffic while dropping new
inbound connections and all forwarding. The rules replace only the
installer-owned `inet workstation` table so independently managed tables,
including Tailscale's, are preserved.

After `fzf` is available through `mise`, switch persistent profiles with:

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

Normal rollback happens from the installed system with:

```bash
sudo rollback-root
```

What `rollback-root` does:

1. Selects the newest completed pre/post pair in the root Snapper configuration.
2. Shows `snapper status PRE..POST` for that pair.
3. Asks for confirmation, including that the consumed snapshots will be deleted.
4. Runs `snapper -c root undochange PRE..POST`.
5. Rebuilds UKIs with `mkinitcpio -P`.
6. Requires the `sbctl` keys, then signs and verifies UKIs.
7. Deletes the consumed pre/post pair only after undo, UKI rebuilding, signing, and verification succeed.
8. Instructs you to reboot before continuing to use the system.

The helper is intended for the pre/post pairs created by `snap-pac`, but it does not filter pairs by description or creator. If you create other root Snapper pre/post pairs, the newest completed one will be selected. The command takes no snapshot-number arguments and does not provide an arbitrary-pair selector.

This is a file-level reversal, not a pacman-managed downgrade. `snapper undochange` reverses the filesystem difference recorded by the pair. It does not run package downgrade transactions or resolve package dependencies. Only files in the root Snapper configuration are affected; sibling subvolumes such as `@home`, `@var_log`, `@sbctl`, and the ESP are not rolled back. `/var/lib/pacman` is inside `@`, so its database changes are included.

What it does not do:

- It does not create safety snapshots.
- It does not maintain rollback journals.
- It does not delete snapshots other than the successfully consumed pair.

If `undochange` succeeds but UKI rebuilding, signing, or verification later fails, the filesystem reversal has already happened and the snapshot pair is retained. Correct the reported boot-artifact problem before rebooting. If only pair deletion fails, the rollback and boot preparation succeeded; delete the retained pair manually using the command printed by `rollback-root`.

Snapper configuration created by the installer:

```text
TIMELINE_CREATE=no
TIMELINE_CLEANUP=no
NUMBER_CLEANUP=no
EMPTY_PRE_POST_CLEANUP=no
```

All snapshots other than a successfully consumed rollback pair are retained until you manually delete them. Running `rollback-root` again selects the previous completed pair, allowing transactions to be undone newest-first.

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

If the installed system still boots, prefer `rollback-root` first. It is narrower: it reverts the newest completed root pre/post pair from inside the running system and is intended for `snap-pac` transactions.

Use `rescue-root` when you need an offline repair environment or when the running system is too broken to trust.

Rescue still requires a valid LUKS unlock method. It cannot bypass encryption. Passphrase-only installations can use their LUKS passphrase. TPM2/FIDO2 installations remove the temporary install-password slot, so the install user's password will not unlock them; use the enrolled token and PIN or a separate recovery key/passphrase slot that you added after installation. Enroll and securely store a backup LUKS unlock method before you need rescue.

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

Both the on-disk rescue environment and custom ISO provide:

```bash
rescue-root
trusted-paccheck
```

`rescue-root` is a guided Bash command with four actions:

```text
Repair installed system
Restore root from snapshot
Check package integrity
Reinstall OS preserving selected state
```

It assumes the disk layout created by this installer:

```text
partition 1 -> ESP
partition 2 -> LUKS+Btrfs root
```

After selecting the disk, choose either token unlock for the enrolled TPM2/FIDO2 method or passphrase/recovery-key unlock for a separately enrolled credential.

It refuses to continue if `/mnt` is already mounted or `/dev/mapper/cryptroot` already exists, because that usually means a previous rescue attempt was not cleaned up.

### Check Package Integrity

Use `trusted-paccheck` when you want to compare installed official Arch package files against metadata reconstructed from signed archive packages.

The guided path is the `rescue-root` menu action `Check package integrity`: it asks how to handle non-official packages, unlocks LUKS, mounts the installed root read-only with `rescue=nologreplay`, runs `trusted-paccheck`, and unmounts and closes LUKS afterwards. `trusted-paccheck` still independently verifies the read-only and `rescue=nologreplay` mount flags before checking anything.

To run it manually instead, mount the installed root read-only at `/mnt` yourself:

```bash
cryptsetup open --token-only ROOT_PARTITION cryptroot
# Or, for an enrolled passphrase/recovery key:
# cryptsetup open --disable-external-tokens ROOT_PARTITION cryptroot
mount -o ro,rescue=nologreplay,noatime,compress=zstd:3,subvol=@ ROOT_DEVICE /mnt
trusted-paccheck
umount /mnt
cryptsetup close cryptroot
```

Unlock LUKS first and use `/dev/mapper/cryptroot` as `ROOT_DEVICE`. The `rescue=nologreplay` option prevents Btrfs tree-log replay from modifying the filesystem during the nominally read-only mount; `trusted-paccheck` requires it. (The standalone `nologreplay` spelling was removed in kernel 6.16; the `norecovery` alias still works and is reported by the kernel as `rescue=nologreplay`.)
Do not select `rescue-root`'s manual-repair action first: that action mounts `@` read-write, and `trusted-paccheck` refuses to run unless its target mount is read-only. Network access is also required to retrieve packages and signatures from the Arch Linux Archive.

`trusted-paccheck` uses the target pacman database only as an inventory of installed package names and versions. It then downloads those exact versions from the Arch Linux Archive, verifies detached package signatures with the rescue keyring, reconstructs verification metadata in a temporary pacman database under `/run`, and runs `paccheck` against `/mnt`. A package omitted from or falsified in the target inventory cannot be discovered independently by this process.

By default it fails before checking if any installed package cannot be retrieved as a signed official Arch package. This catches AUR/custom packages instead of silently omitting them. To check official packages and explicitly report skipped foreign/custom packages, run:

```bash
trusted-paccheck --official-only
```

It checks files belonging to the retrieved official packages. Paccheck's default exclusions mean hashes and properties are not fully checked for pacman backup/config files and `NoExtract`/`NoUpgrade` entries, so expected local configuration changes are not comprehensively audited. It does not verify skipped AUR/custom packages, custom files from this installer, user data, `/efi` UKIs, or extra files dropped outside package ownership.

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
- The normal `rollback-root` path is unavailable because the system does not boot.
- You want the entire root filesystem back at the selected snapshot state.

Do not choose root replacement for a small targeted fix. Use manual repair when you only need to edit a file, rebuild UKIs, inspect logs, or copy data.

Root replacement affects the `@` subvolume only. It does not roll back sibling subvolumes such as `@home`, `@iwd`, `@sbctl`, `@tailscale`, `@netbird`, `@portables`, `@flatpak`, or `@libvirt`.

`rescue-root` lists every snapshot directory and description; it does not restrict the menu to pacman snapshots or identify the correct member of a pair for you. To reverse a failed `snap-pac` transaction, select the `pre` snapshot created immediately before that transaction, normally the lower-numbered member of its pre/post pair. The matching `post` snapshot represents the state after the transaction and normally reproduces the bad state. If the description and numbers do not make the intended state clear, cancel and inspect the snapshots before replacing `@`.

Before changing `@`, the selected snapshot must provide `/efi` and `/var/lib/sbctl` mount-point directories and working `mkinitcpio`, `sbctl`, and `jq` commands. The preserved `@sbctl` subvolume must contain the Secure Boot keys, and the ESP must contain the current normal UKI so it can be backed up. `rescue-root` stops before promotion if these prerequisites or boot preparation fail.

Root replacement does this:

1. Select the installed disk.
2. Treat partition 1 as the ESP and partition 2 as root.
3. Unlock LUKS.
4. Mount the Btrfs top-level volume at `/mnt`.
5. List snapshots from `@snapshots`.
6. Ask which snapshot should become the new `@`.
7. Create a temporary replacement root named `@new-rollback-<timestamp>`.
8. Mount the ESP and `@sbctl` inside the temporary replacement.
9. Back up the current UKIs, rebuild with `mkinitcpio -P`, then sign and verify them from the temporary replacement.
10. Move the current `@` to `@old-<timestamp>` only after boot preparation succeeds.
11. Move the temporary replacement into place as the new `@`.
12. Set and verify the Btrfs default subvolume by ID.
13. Unmount everything and close LUKS.
14. Offer to reboot.

The selected source snapshot remains under `@snapshots`; root replacement does not delete it. After success, reboot to start the restored root and rebuilt UKI, then verify the system before deleting either the source snapshot or retained old root.

If root promotion fails, `rescue-root` verifies subvolume identities before restoring the original `@`, original default subvolume, and backed-up UKIs. The failed candidate may be retained as `@new-rollback-<timestamp>` or `@failed-<timestamp>` for inspection. Delete it only after the original system is verified.

If `DO NOT REBOOT` is printed:

1. Stay in the rescue environment. UKI backups under `/run` disappear on reboot.
2. If the error prints only a UKI backup path, promotion never started and the original `@` is unchanged. Do not rename subvolumes. Mount the ESP at a temporary directory under `/run`, restore `arch-linux.efi` and, when present, `arch-rescue.efi` from that backup directory, then verify the restored files.
3. If the error also prints original root, original default, and replacement root IDs, automatic promotion recovery failed and the Btrfs names/default may be incomplete. Record all printed IDs and the UKI backup path.
4. For a promotion-recovery failure, reopen LUKS if cleanup closed it, then mount the Btrfs top level with `mount -o subvolid=5 /dev/mapper/cryptroot /mnt`.
5. Run `btrfs subvolume list /mnt` and identify subvolumes by the printed IDs, not by names alone. The original may be named `@` or `@old-*`; the replacement may be named `@`, `@new-rollback-*`, or `@failed-*`.
6. Ensure the printed original root ID is named `@`, moving any replacement at `@` aside first. Restore the default with `btrfs subvolume set-default ORIGINAL_DEFAULT_ID /mnt`, using the separately printed original default ID rather than assuming it equals the root ID.
7. Restore the backed-up UKIs from a temporary ESP mount under `/run`, then verify the root ID, default ID, and UKIs before unmounting, closing LUKS, and rebooting. If any identity is uncertain, do not rename or delete subvolumes.

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

Prefer the narrower tools when they fit: `rollback-root` for one bad pacman transaction, root replacement for restoring a known-good snapshot, a full fresh install when the disk layout or encryption itself should change or the machine changes hands.

These subvolumes always survive reinstall:

```text
@sbctl @iwd @tailscale @netbird
```

`@home` is preserved by default. You may instead choose to erase it; that choice requires typing `ERASE` at its own confirmation and there is no retained copy — a chosen wipe means the data is actually gone. Every other subvolume (`@snapshots`, `@root`, `@var_log`, `@var_cache`, `@var_tmp`, container/VM storage, `@srv`) is deleted and recreated empty; previous Snapper snapshots are gone after reinstall. The current `@` is not deleted: it is renamed to `@old-reinstall-<timestamp>` and retained until you verify the reinstalled system, so a mid-reinstall failure (network loss during pacstrap, mirror outage) leaves the previous root intact and re-running the action is safe.

Reinstall does this:

1. Print the embedded payload version. The packages and settings used for reinstall are frozen into the rescue image at ISO build time; rebuilding the ISO refreshes them. Reinstalling from an old rescue image is a conscious choice.
2. Select the installed disk, treat partition 1 as ESP and partition 2 as LUKS root, and unlock it.
3. Verify the installer layout fingerprint: `@`, `@home`, and every always-preserved subvolume must exist, `@sbctl` must contain key material, and the ESP must mount. Anything else is not an installer-created system and the action refuses.
4. Check network reachability, refresh `archlinux-keyring` in the rescue environment, and validate all package names — all before anything destructive.
5. Ask for hostname, timezone, Bluetooth/Thunderbolt toggles, username, and password. The LUKS boot unlock method is detected from the LUKS2 header (`systemd-tpm2`/`systemd-fido2` tokens, otherwise passphrase), never freely chosen: a wrong `crypttab.initramfs` on a token-only system is unbootable. No tokens are enrolled or wiped.
6. Show the effective preserve and recreate sets and require confirmation.
7. Retire `@`, delete and recreate the recreate set (child subvolumes first), set the new `@` as the Btrfs default subvolume, and mount the full target layout.
8. Run `pacstrap`, generate `fstab`, install the payload package selection, and regenerate the target configuration exactly like the fresh installer, including Snapper with deferred `snap-pac`.
9. Sign and verify systemd-boot, the new UKI, the existing on-ESP rescue UKI, and `fwupd` with the preserved `@sbctl` keys, and recreate the `Linux Boot Manager` firmware entry.
10. Unmount, close LUKS, and offer to reboot.

The user account is recreated first, so it gets UID/GID 1000 like the fresh installer; with `@home` preserved, existing file ownership stays correct and ownership is verified after creation. SSH host keys are regenerated by the reinstall, so remote clients will show host-key-changed warnings on first connect; this is expected, not an attack.

Delete the retained old root only after verifying the reinstalled system, the same way as `@old-<timestamp>` above:

```bash
mount -o subvolid=5 /dev/mapper/cryptroot /mnt
btrfs subvolume delete /mnt/@old-reinstall-<timestamp>
umount /mnt
```

## 5. Reference

Important paths:

```text
install.bash                                      main installer
iso/build.sh                                      custom ISO build script
iso/out/                                          generated ISO output, gitignored
artifacts/arch-rescue.efi                         generated rescue UKI intermediate, removed after successful ISO build
iso/airootfs/usr/local/bin/install-arch           live ISO installer launcher
iso/airootfs/usr/local/bin/rescue-root            live ISO rescue launcher
iso/airootfs/usr/local/bin/trusted-paccheck       live/rescue package integrity checker
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
/efi/EFI/systemd/systemd-bootx64.efi
/efi/EFI/BOOT/BOOTX64.EFI
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
/efi/loader/loader.conf
/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed   signed source copy used by future systemd-boot updates
```

`iso/build.sh` clears old ISO outputs before each build, then removes rescue UKI and mkosi intermediate outputs after a successful build. The new final ISO remains under `iso/out/`.
