# Rescue Reinstall Implementation Plan

This plan tracks the V2 rescue reinstall feature described in `rescue-roadmap.md`.

`README.md` remains the source of truth for current behavior. This file is a checklist for future implementation work.

## Goal

Add a third `rescue-root` action:

```text
Reinstall OS preserving selected state
```

The action runs from `arch-rescue`, unlocks the existing installed LUKS root, keeps the existing partition table, ESP, LUKS container, Btrfs filesystem, and fixed preserve-set subvolumes, recreates the OS-managed subvolumes, reinstalls packages/settings, rebuilds/signs UKIs, and recreates the `arch-linux` and `arch-rescue` firmware entries.

## Non-Goals

- Do not repartition the disk.
- Do not reformat the ESP.
- Do not recreate or erase the LUKS container.
- Do not enroll Secure Boot keys.
- Do not require firmware Secure Boot Setup Mode.
- Do not preserve unknown state.
- Do not support arbitrary non-installer Arch layouts.
- Do not create a second full installer implementation.
- Do not add backup/journal machinery; the user is responsible for backups.

## Fixed Preserve Set

These Btrfs subvolumes survive reinstall:

```text
@home
@sbctl
@iwd
@tailscale
@netbird
```

## Fixed Recreate Set

These Btrfs subvolumes are deleted and recreated:

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

## Phase 1: Rescue UKI Runtime Support

- [x] Add `curl` to `rescue-uki/mkosi.conf` for the installer network check.
- [x] Add `pciutils` to `rescue-uki/mkosi.conf` for `lspci` GPU detection.
- [x] Add `libfido2` to `rescue-uki/mkosi.conf` for systemd LUKS2 FIDO2 unlock support.
- [x] Add `tpm2-tss` to `rescue-uki/mkosi.conf` for systemd LUKS2 TPM2 unlock support.
- [x] Add `iptables` to `rescue-uki/mkosi.conf` and `iso/packages.x86_64` to avoid the `libxtables.so` provider prompt.
- [ ] Do not add `git`; V2 should not require cloning the installer during rescue.
- [ ] Do not add `mkosi`, `archiso`, or `openssl`; those are build-time tools, not rescue reinstall runtime tools.
- [ ] Confirm `mkosi -C rescue-uki --no-pager summary` still succeeds.

## Phase 2: Rescue Installer Payload

V2 needs more than the current `rescue-root` script. It needs package lists, static settings, and shared installer logic available inside the rescue image.

- [ ] Choose rescue payload path: `/usr/local/share/arch-new-install`.
- [ ] Update `rescue-uki/build.sh` to copy the required payload into `rescue-uki/mkosi.extra/usr/local/share/arch-new-install` before `mkosi build`.
- [ ] Update `rescue-uki/build.sh` cleanup to remove the copied payload on exit.
- [ ] Copy `packages/` into the payload.
- [ ] Copy `settings/` into the payload.
- [ ] Copy `installer-common.bash` into the payload after it exists.
- [ ] Copy only files required for rescue reinstall; do not embed `.git`, ISO outputs, mkosi outputs, or release credentials.
- [ ] Keep the existing temporary copy of `rescue-root` as `/usr/local/bin/rescue-root`.

## Phase 3: Shared Installer Code

Create a shared Bash file:

```text
installer-common.bash
```

`common` means the code is shared by the USB installer and the rescue reinstall path.

- [ ] Move `BTRFS_MOUNT_OPTIONS` into `installer-common.bash`.
- [ ] Move `BTRFS_SUBVOLUMES` into `installer-common.bash`.
- [ ] Move `BTRFS_SUBVOLUME_MOUNTS` into `installer-common.bash`.
- [ ] Add `BTRFS_PRESERVE_SUBVOLUMES` for the fixed preserve set.
- [ ] Add `BTRFS_RECREATE_SUBVOLUMES` for the fixed recreate set.
- [ ] Move `partition_path` into `installer-common.bash`.
- [ ] Move package-file collection into `installer-common.bash`.
- [ ] Move package-name validation into `installer-common.bash`.
- [ ] Keep deferred `snap-pac` validation behavior in shared package validation.
- [ ] Move `target_chroot` into `installer-common.bash`.
- [ ] Move settings copy helpers into `installer-common.bash`.
- [ ] Move `append_unique_lines` into `installer-common.bash`.
- [ ] Move systemd enable/mask helpers into `installer-common.bash`.
- [ ] Move EFI boot-entry deletion by exact label into `installer-common.bash`.
- [ ] Move optional EFI/NVRAM cleanup prompt into `installer-common.bash`.
- [ ] Move UKI/fwupd signing helpers into `installer-common.bash`.
- [ ] Move GPU detection into `installer-common.bash`.
- [ ] Move microcode detection into `installer-common.bash`.

## Phase 4: Keep Fresh Install Behavior Unchanged

After adding `installer-common.bash`, refactor `install.bash` to source it without changing fresh install behavior.

- [ ] Source `installer-common.bash` from `install.bash`.
- [ ] Remove duplicated constants from `install.bash`.
- [ ] Replace duplicated helper functions in `install.bash` with shared functions.
- [ ] Keep fresh install disk partitioning exactly as-is.
- [ ] Keep fresh install ESP formatting exactly as-is.
- [ ] Keep fresh install LUKS creation exactly as-is.
- [ ] Keep fresh install Secure Boot key creation/enrollment exactly as-is.
- [ ] Keep fresh install `arch-linux` and `arch-rescue` EFI entries exactly as-is.
- [ ] Keep fresh install `fwupd` config/signing exactly as-is.
- [ ] Run syntax/static checks before adding the rescue reinstall action.

## Phase 5: Add Rescue Reinstall Menu Action

Add a third action to `iso/airootfs/usr/local/bin/rescue-root`:

```text
Reinstall OS preserving selected state
```

- [ ] Source `/usr/local/share/arch-new-install/installer-common.bash` when running inside the rescue UKI.
- [ ] Keep existing `Mount installation and enter a repair shell` behavior unchanged.
- [ ] Keep existing `Replace @ from a Snapper snapshot` behavior unchanged.
- [ ] Add `reinstall_preserving_state` as the implementation function for the new action.
- [ ] Fail clearly if the shared installer payload is missing.

## Phase 6: Reinstall Preflight

The reinstall action supports only systems created by this installer.

- [ ] Select installed disk with the existing disk selector.
- [ ] Treat partition 1 as ESP.
- [ ] Treat partition 2 as root.
- [ ] Require partition 2 to be LUKS.
- [ ] Unlock the existing LUKS root.
- [ ] Mount the Btrfs top-level volume at `/mnt` with `subvolid=5`.
- [ ] Verify all preserve-set subvolumes exist.
- [ ] Verify all recreate-set subvolumes exist, except tolerate missing subvolumes only if explicitly decided before implementation.
- [ ] Verify `@sbctl` contains usable `sbctl` key material.
- [ ] Verify the ESP partition can be mounted.
- [ ] Verify package names before deleting/recreating any subvolumes.
- [ ] Show the fixed preserve set.
- [ ] Show the fixed recreate set.
- [ ] Require explicit confirmation before deleting subvolumes.

## Phase 7: Reinstall Prompts

Ask only for values needed to regenerate the new root system.

- [ ] Ask for hostname.
- [ ] Ask for timezone.
- [ ] Ask for username.
- [ ] Ask for user password.
- [ ] Ask for existing LUKS unlock method to configure: passphrase-only, TPM2 + PIN, or FIDO2 + PIN.
- [ ] Do not run `systemd-cryptenroll`.
- [ ] Do not wipe LUKS password slots.
- [ ] Do not create new LUKS credentials.

## Phase 8: Delete And Recreate Subvolumes

The Btrfs layout uses sibling subvolumes, but `@snapshots` contains child snapshot subvolumes. Delete child subvolumes first.

- [ ] Build a helper that deletes a Btrfs subvolume tree child-first.
- [ ] Use `btrfs subvolume list` to find child subvolumes under each recreate-set subvolume.
- [ ] Delete child subvolumes before deleting their parent.
- [ ] Delete each recreate-set subvolume.
- [ ] Recreate each recreate-set subvolume.
- [ ] Do not delete preserve-set subvolumes.
- [ ] Do not delete unknown subvolumes outside the fixed recreate set.
- [ ] Set the Btrfs default subvolume to `@` if needed.

## Phase 9: Mount Target Layout

- [ ] Unmount the top-level mount.
- [ ] Mount new `@` at `/mnt`.
- [ ] Mount recreated sibling subvolumes at their target paths.
- [ ] Mount preserved `@home` at `/mnt/home`.
- [ ] Mount preserved `@sbctl` at `/mnt/var/lib/sbctl`.
- [ ] Mount preserved `@iwd` at `/mnt/var/lib/iwd`.
- [ ] Mount preserved `@tailscale` at `/mnt/var/lib/tailscale`.
- [ ] Mount preserved `@netbird` at `/mnt/var/lib/netbird`.
- [ ] Mount the existing ESP at `/mnt/efi`.
- [ ] Apply required permissions for `/mnt/root` and `/mnt/var/tmp`.

## Phase 10: Reinstall Base System And Packages

- [ ] Detect CPU microcode.
- [ ] Run `pacstrap -K /mnt base base-devel linux linux-headers "$microcode" linux-firmware`.
- [ ] Generate `/mnt/etc/fstab` with `genfstab -U /mnt`.
- [ ] Install selected package files from the embedded rescue payload.
- [ ] Keep `snap-pac` deferred until after Snapper is configured.
- [ ] Do not install Docker packages; container subvolumes are storage boundaries only.

## Phase 11: Regenerate Target Configuration

Split target configuration so reinstall can reuse normal installer behavior without running fresh-install-only steps.

- [ ] Generate `/etc/hostname`.
- [ ] Generate `/etc/hosts`.
- [ ] Generate locale config.
- [ ] Generate vconsole config.
- [ ] Generate timezone symlink.
- [ ] Generate `/etc/crypttab.initramfs` from the selected existing unlock method.
- [ ] Generate `/etc/cmdline.d/root.conf` with `root=/dev/mapper/cryptroot`.
- [ ] Install `/etc/mkinitcpio.conf` from the encrypted variant.
- [ ] Install `/etc/mkinitcpio.d/linux.preset`.
- [ ] Install static settings from the embedded rescue payload.
- [ ] Install `fwupd` config with `DisableShimForSecureBoot=true`.
- [ ] Configure services like the normal installer.
- [ ] Preserve existing iwd state by mounting `@iwd`; do not overwrite it with rescue Wi-Fi credentials.
- [ ] Create or update the requested user account.
- [ ] Handle an existing `/home/$username` directory without deleting it.
- [ ] Set the requested user password.
- [ ] Lock the root account.

## Phase 12: Snapper And Pacman Hooks

- [ ] Configure Snapper for the new `@` root.
- [ ] Mount recreated `@snapshots` at `/.snapshots`.
- [ ] Keep Snapper cleanup disabled.
- [ ] Install `snap-pac` only after Snapper is configured.
- [ ] Accept that previous Snapper snapshots are deleted because `@snapshots` is in the recreate set.

## Phase 13: Boot Files And Secure Boot

- [ ] Rebuild UKIs with `mkinitcpio -P`.
- [ ] Keep existing `/efi/EFI/Linux/arch-rescue.efi` unless V2 explicitly embeds a replacement rescue UKI artifact.
- [ ] Sign `/efi/EFI/Linux/arch-linux.efi` with preserved `@sbctl` keys.
- [ ] Sign `/efi/EFI/Linux/arch-rescue.efi` when present.
- [ ] Sign `/usr/lib/fwupd/efi/fwupdx64.efi` to `/usr/lib/fwupd/efi/fwupdx64.efi.signed`.
- [ ] Run `sbctl verify`.
- [ ] Delete existing `arch-linux` firmware entries by exact label.
- [ ] Delete existing `arch-rescue` firmware entries by exact label.
- [ ] Recreate the `arch-linux` firmware entry.
- [ ] Recreate the `arch-rescue` firmware entry.
- [ ] Do not call `sbctl create-keys`.
- [ ] Do not call `sbctl enroll-keys`.

## Phase 14: Cleanup And Exit

- [ ] Remove temporary sudoers files if any were created.
- [ ] Unmount `/mnt` recursively.
- [ ] Close `/dev/mapper/cryptroot`.
- [ ] Offer to reboot.
- [ ] Print clear manual cleanup instructions if unmount or close fails.

## Phase 15: Validation Commands

Run after each significant phase:

```bash
bash -n install.bash iso/build.sh rescue-uki/build.sh rescue-uki/mkosi.finalize rescue-uki/mkosi.postinst.chroot rescue-uki/mkosi.version iso/release.sh iso/airootfs/usr/local/bin/rescue-root iso/airootfs/usr/local/bin/install-arch settings/rollback/usr/local/sbin/rollback-root
```

```bash
shellcheck install.bash iso/build.sh rescue-uki/build.sh rescue-uki/mkosi.finalize rescue-uki/mkosi.postinst.chroot rescue-uki/mkosi.version iso/release.sh iso/airootfs/usr/local/bin/rescue-root iso/airootfs/usr/local/bin/install-arch settings/rollback/usr/local/sbin/rollback-root
```

```bash
git diff --check
```

Run when package/image changes are made:

```bash
mkosi -C rescue-uki --no-pager summary
```

Do not run the full ISO build during routine implementation unless explicitly requested:

```bash
sudo ./iso/build.sh
```

## Phase 16: Test Matrix

- [ ] Fresh USB installer still passes scripted checks.
- [ ] Current rescue manual mount action still works.
- [ ] Current rescue root replacement action still works.
- [ ] Rescue UKI still builds.
- [ ] Custom ISO still builds.
- [ ] VM fresh install works.
- [ ] VM `arch-rescue` boot works.
- [ ] VM rescue reinstall works with passphrase-only unlock config.
- [ ] VM rescue reinstall works with FIDO2 + PIN unlock config.
- [ ] VM rescue reinstall works with TPM2 + PIN unlock config if TPM2 VM testing is practical.
- [ ] Preserved `@home` remains mounted and user data remains present after reinstall.
- [ ] Preserved `@sbctl` signs new UKIs after reinstall.
- [ ] Preserved `@iwd` Wi-Fi profiles remain present after reinstall.
- [ ] Normal boot works after reinstall.
- [ ] Secure Boot verification succeeds after reinstall.
- [ ] Firmware entries contain `arch-linux` and `arch-rescue` after reinstall.

## Implementation Order

Use small commits in this order:

1. Add rescue UKI runtime packages.
2. Add `installer-common.bash` with shared constants only.
3. Move low-risk shared helpers into `installer-common.bash`.
4. Refactor `install.bash` to use shared helpers with no behavior change.
5. Embed the rescue installer payload.
6. Add the third `rescue-root` menu action with preflight only.
7. Add subvolume deletion/recreation.
8. Add reinstall package/config generation.
9. Add UKI signing and firmware entry recreation.
10. Test in VM before hardware.
