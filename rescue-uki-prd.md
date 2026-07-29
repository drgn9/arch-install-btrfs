# Rescue UKI PRD

## Purpose

Add an on-disk rescue Unified Kernel Image (UKI) for machines installed by this project.

The rescue UKI should live on the EFI System Partition (ESP), be signed by the installed system's existing `sbctl` keys, and boot directly from firmware as an additional EFISTUB entry. It is intended for rescue and rollback operations when the USB installer is unavailable.

This document is the product requirements document for building that feature.

## Current Separation Of Concerns

The existing USB ISO installer remains the first-time installation path.

USB ISO responsibilities:

- Fresh destructive installation.
- Disk partitioning and formatting.
- Initial Btrfs subvolume creation.
- Initial LUKS setup.
- Initial package installation and system configuration.
- Initial Secure Boot key creation/enrollment exactly as handled by the current installer flow.
- Current behavior remains unchanged for V1.

Rescue UKI responsibilities:

- Boot from the already-installed machine's ESP.
- Boot under already-established Secure Boot trust.
- Provide rescue and rollback operations currently available from the custom ISO's `rescue-arch` command.
- Avoid dependency on Ventoy or a USB stick for ordinary rescue.

## Version 1 Scope

V1 creates and installs a rescue UKI that can do the same rescue and rollback operations that the ISO currently provides through `rescue-arch`.

V1 must support:

- Booting a minimal Arch rescue system from a single `.efi` file.
- Placing that `.efi` file on the ESP at a stable path.
- Signing the rescue UKI with `sbctl`.
- Creating a direct EFI boot entry for the rescue UKI.
- Running `rescue-arch` from the rescue environment.
- Unlocking the installed system's LUKS root if needed.
- Mounting the installed root subvolume and ESP for chroot repair.
- Replacing `@` from an existing Snapper snapshot.
- Rebuilding installed-system UKIs with `mkinitcpio -P`.
- Signing/verifying installed-system UKIs with `sbctl` when preserved keys exist.

V1 must not implement reinstall mode.

## Version 1 Non-Goals

V1 must not:

- Replace the existing USB ISO installer.
- Change the existing first-time installation flow.
- Change the existing Secure Boot enrollment flow in `install.bash`.
- Introduce `systemd-boot`.
- Require Ventoy.
- Store or embed Secure Boot private keys in the rescue UKI.
- Implement `rescue-reinstall.bash`.
- Preserve or delete subvolumes for reinstall.
- Become a general-purpose full Arch live ISO replacement.

## Boot Model

Keep the current direct-UKI / EFISTUB model.

Normal installed boot targets:

```text
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-linux-lts.efi
```

New rescue boot target:

```text
/efi/EFI/Linux/arch-rescue.efi
```

EFI boot entries:

```text
arch-linux
arch-linux-lts
arch-rescue
```

The rescue UKI should be bootable directly from firmware. No bootloader is required.

## Secure Boot Model

The rescue UKI must be signed with the installed system's existing `sbctl` keys.

Expected signing command:

```bash
sbctl sign -s /efi/EFI/Linux/arch-rescue.efi
```

V1 assumes the machine has already been through the normal first-time installer and Secure Boot setup path.

V1 does not create, import, restore, or enroll Secure Boot keys.

V1 does not require firmware Setup Mode.

If the machine does not already trust the signing key, the rescue UKI will not boot under Secure Boot. That is expected.

## Rescue UKI Build Approach

Use `mkosi` to build a minimal rescue image as a UKI.

The explored `archrescue` and `archlinux-rescue-image` projects demonstrate the right pattern:

- `mkosi.conf`
- `Format=uki`
- minimal Arch package set
- root password via `mkosi.rootpw`
- optional secure boot signing with external tools
- output as a single `.efi` artifact

This project should include its own rescue UKI build directory rather than adopting either project verbatim.

Proposed directory:

```text
rescue-uki/
├── mkosi.conf
├── mkosi.extra/
├── mkosi.finalize
├── mkosi.postinst.chroot
├── mkosi.version
└── build.sh
```

The build should bake the current installer repository into the rescue image at:

```text
/root/arch-new-install
```

That path matches the custom ISO convention.

The rescue image should expose a simple launcher:

```text
/usr/local/bin/rescue-arch
```

The launcher should run the repository copy's rescue script, or the rescue script itself should be installed directly into the image.

## Rescue UKI Package Requirements

The rescue UKI should include only what is needed for rescue and rollback.

Required packages:

```text
base
linux-lts
linux-firmware
arch-install-scripts
btrfs-progs
cryptsetup
efibootmgr
sbctl
snapper
rsync
gum
impala
iwd
systemd
util-linux
dosfstools
vim
less
man-pages
mandoc
```

Package notes:

- `linux-lts` is preferred for the rescue image for stability.
- `arch-install-scripts` provides `arch-chroot`.
- `btrfs-progs` is required for subvolume operations.
- `cryptsetup` is required for LUKS unlock.
- `sbctl` is required to sign/verify installed-system UKIs.
- `snapper` is required to inspect snapshots if needed.
- `gum` is required by `rescue-arch` menus.
- `impala` and `iwd` provide Wi-Fi setup if networking is needed.
- `rsync` is useful for rescue copies and backups.

Optional packages to consider later:

```text
nano
tmux
curl
wget
jq
age
```

V1 should avoid adding optional packages unless a concrete rescue workflow needs them.

## Networking

Keep networking simple.

Preferred V1 networking stack:

```text
iwd + impala
```

The rescue image should start `iwd.service` or make it easy to start.

The login message should tell the user:

```bash
impala
```

Ethernet should work if the selected networking stack configures DHCP. If DHCP is not automatic in V1, document the manual command needed.

Network is not required for local rollback from existing snapshots, but it is useful for package repair or data transfer.

## Root Login

The rescue image must be login-capable.

`mkosi.rootpw` is generated by the build helper, not by the user.

During the single top-level build command:

```bash
sudo ./iso/build.sh
```

the internal rescue UKI helper must:

1. Prompt for the rescue root password.
2. Prompt for confirmation.
3. Reject empty or mismatched passwords.
4. Hash the password.
5. Write `rescue-uki/mkosi.rootpw` temporarily.
6. Build the rescue UKI.
7. Delete `rescue-uki/mkosi.rootpw` automatically on exit, success, failure, or interrupt.

`mkosi.rootpw` must still be gitignored as a safety net.

Autologin is out of scope for V1 unless explicitly added later.

## Rescue Commands

V1 must reuse the existing rescue script:

```text
iso/airootfs/usr/local/bin/rescue-arch
```

V1 must not create a second rescue implementation or duplicate this logic in a new script. The rescue UKI should package the existing script and expose it as the primary command in the rescue environment:

```bash
rescue-arch
```

The existing `rescue-arch` behavior is the V1 functional contract. It currently provides two actions:

```text
Mount installation and enter a repair shell
Replace @ from a Snapper snapshot
```

### Mount Installation And Repair Manually

This existing action currently:

1. Select the installed disk.
2. Determine partition 1 as ESP and partition 2 as root, matching this installer's layout.
3. Unlock LUKS if present.
4. Mount `@` at `/mnt`.
5. Mount the ESP at `/mnt/efi` when present.
6. Print instructions for chroot repair.

The current simplified mount behavior should remain:

```text
@   -> /mnt
ESP -> /mnt/efi
```

The existing rescue script should continue telling the user to run the following inside the chroot if additional subvolumes are needed:

```bash
mount -a
```

### Replace `@` From A Snapper Snapshot

This existing action currently:

1. Select the installed disk.
2. Unlock LUKS if present.
3. Mount the Btrfs top-level volume.
4. List snapshots from `@snapshots`.
5. Let the user choose a snapshot.
6. Create a temporary replacement root from the selected snapshot.
7. Move current `@` to `@old-<timestamp>`.
8. Promote the temporary replacement to `@`.
9. Mount the restored system.
10. Run `mkinitcpio -P` in the chroot.
11. Sign and verify UKIs if `sbctl` keys exist.
12. Unmount and close LUKS if opened.
13. Offer to reboot.

V1 packaging must preserve the safety fixes already made to `rescue-arch`:

- cleanup on failed exits
- temporary replacement root before moving current `@`
- interrupt protection around the critical rename window

## Installation To ESP

The normal top-level build command must build the rescue UKI before building the USB ISO.

The user-facing build command remains exactly one command:

```bash
sudo ./iso/build.sh
```

Users must not have to remember to build the rescue UKI separately.

Internally, `iso/build.sh` may call a helper script:

```text
rescue-uki/build.sh
```

but that helper is not a separate required user workflow.

The helper must always prompt for the rescue root password during the top-level build, create `mkosi.rootpw` temporarily, run the `mkosi` build, and delete `mkosi.rootpw` automatically on exit, success, failure, or interrupt.

The normal installed system should receive the already-built rescue UKI from the USB installer and install it on the ESP.

Internal helper path:

```text
rescue-uki/build.sh
```

V1 build/install workflow:

```bash
sudo ./iso/build.sh
```

That command builds the rescue UKI, embeds it in the USB ISO, and the installer later copies/signs/registers it during installation.

The installer must install the rescue UKI automatically during first-time installation. There is no manual post-install rescue UKI setup step in V1.

## EFI Boot Entry

V1 should create a direct firmware boot entry for the rescue UKI.

Expected command shape:

```bash
efibootmgr --create \
    --disk "$target_disk" \
    --part 1 \
    --label "arch-rescue" \
    --loader "\\EFI\\Linux\\arch-rescue.efi" \
    --unicode
```

The first implementation may make this a manual documented command instead of automating it.

If automated, it should remove existing `arch-rescue` entries first, using the same pattern as the current installer uses for `arch-linux` and `arch-linux-lts`.

## Output And Gitignore

Generated rescue UKI outputs should not be committed.

The rescue UKI build directory should gitignore:

```text
mkosi.output/
mkosi.cache/
mkosi.local/
mkosi.local.conf
.mkosi-private/
mkosi.rootpw
```

Do not commit root passwords.

Do not commit generated `.efi` artifacts.

Do not commit local signing keys.

## Acceptance Criteria For V1

V1 is complete when:

- `mkosi build` produces a rescue `.efi` artifact.
- The rescue `.efi` installs to `/efi/EFI/Linux/arch-rescue.efi`.
- `sbctl sign -s /efi/EFI/Linux/arch-rescue.efi` succeeds.
- `sbctl verify /efi/EFI/Linux/arch-rescue.efi` succeeds.
- An `arch-rescue` EFI boot entry can boot the rescue environment.
- The rescue environment allows root login.
- `rescue-arch` is available in the rescue environment.
- `rescue-arch` can mount the installed system for manual repair.
- `rescue-arch` can replace `@` from a Snapper snapshot.
- After snapshot replacement, installed-system UKIs are rebuilt and signed.
- The current USB ISO installer behavior is unchanged.

## Testing Plan For V1

Initial testing should happen in a VM.

Test cases:

1. Build rescue UKI.
2. Install rescue UKI to ESP.
3. Sign rescue UKI.
4. Boot rescue UKI from firmware entry.
5. Confirm root login works.
6. Confirm `rescue-arch` exists.
7. Confirm LUKS unlock works for the installed system.
8. Confirm manual repair mount works.
9. Confirm `arch-chroot /mnt` works.
10. Confirm `mount -a` inside chroot mounts remaining fstab entries if needed.
11. Confirm snapshot listing works.
12. Confirm root replacement from snapshot works.
13. Confirm `mkinitcpio -P` runs in the restored system.
14. Confirm `sbctl verify` succeeds after signing.
15. Confirm normal system boots after rescue operation.

Physical-machine testing should happen only after VM testing succeeds.

## Risks

ESP corruption or disk failure:

- The rescue UKI lives on the same disk's ESP.
- It is not a replacement for external install media.
- Keep the USB ISO for first-time install and catastrophic disk recovery.

Secure Boot trust:

- The rescue UKI must be signed with a key already trusted by firmware.
- If Secure Boot trust is broken, the rescue UKI may not boot.

LUKS unlock support:

- The rescue environment must support the installed system's unlock method.
- FIDO2/TPM2-only systems need the relevant systemd/cryptsetup support available in the rescue image.

Image freshness:

- The rescue UKI should be rebuilt periodically.
- A stale rescue image may still boot, but package/keyring/network tooling may be outdated.

ESP space:

- The ESP must have enough space for normal UKIs and the rescue UKI.
- The existing 1 GiB ESP is expected to be sufficient, but actual image size must be checked.

## Version 2 Future Scope: Rescue Reinstall

V2 may add `rescue-reinstall.bash`.

This is explicitly not part of V1.

The V2 goal would be a fresh reinstall from the rescue UKI on an already-owned machine, without firmware Setup Mode and without USB media.

V2 reinstall model:

- Preserve only explicitly selected persistent subvolumes.
- Delete and recreate all other installer-managed subvolumes.
- Reuse preserved `@sbctl` to sign newly generated UKIs.
- Never enroll Secure Boot keys.
- Never require firmware Setup Mode.

V2 preserve set:

```text
@home
@sbctl
@iwd
@tailscale
@netbird
```

V2 delete/recreate set:

```text
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
@flatpak
@libvirt
@srv
```

V2 would need careful refactoring before implementation.

Likely implementation prerequisite:

```text
installer-lib.bash
```

Shared code would be moved out of `install.bash` so the normal USB installer and the future reinstall path can reuse:

- package collection
- package validation
- pacstrap/package installation helpers
- settings installation
- target configuration
- Snapper setup
- UKI signing logic
- Btrfs layout constants

V2 must not duplicate the entire installer in a second large script.

## Recommended V1 Implementation Direction

Keep V1 small.

Recommended steps:

1. Add `rescue-uki/` based on the simpler parts of `archrescue`.
2. Make `sudo ./iso/build.sh` build the rescue UKI first.
3. Make `rescue-uki/build.sh` always prompt for the rescue root password and always delete the temporary `mkosi.rootpw` file.
4. Copy the generated rescue UKI to `artifacts/arch-rescue.efi`.
5. Explicitly bake `artifacts/arch-rescue.efi` into the USB ISO.
6. Make `install.bash` copy the rescue UKI to `/efi/EFI/Linux/arch-rescue.efi`.
7. Make `install.bash` sign the rescue UKI with `sbctl` during the current Secure Boot flow.
8. Make `install.bash` create an `arch-rescue` EFI boot entry.
9. Test in a VM.
10. Defer reinstall mode until V2.
