# Rescue Reinstall Implementation Plan

This plan tracks the future V2 rescue reinstall feature.

`README.md` remains the source of truth for current behavior. This file is a checklist for future implementation work.

## Goal

Add a new `rescue-root` action:

```text
Reinstall OS preserving selected state
```

The action runs from `arch-rescue`, unlocks the existing installed LUKS root, keeps the existing partition table, ESP, LUKS container, Btrfs filesystem, and always-preserved subvolumes (plus `@home` unless the user chooses to erase it), retires the current root aside and recreates the OS-managed subvolumes, reinstalls packages/settings, rebuilds/signs UKIs, reinstalls signed systemd-boot files, and recreates the `Linux Boot Manager` firmware entry.

## Non-Goals

- Do not repartition the disk.
- Do not reformat the ESP.
- Do not recreate or erase the LUKS container.
- Do not enroll Secure Boot keys.
- Do not require firmware Secure Boot Setup Mode.
- Do not preserve unknown state.
- Do not support arbitrary non-installer Arch layouts.
- Do not create a second full installer implementation.
- Do not add backup/journal machinery; the user is responsible for data backups. Retaining the previous root subvolume until reinstall succeeds is transactional safety, not backup machinery, and is in scope.
- Keep the installed system policy aligned with the normal installer: mandatory LUKS root, mandatory Secure Boot, mandatory `lockdown=integrity`, signed systemd-boot with signed Type #2 UKIs, and no GRUB.

## Preserve Set

These Btrfs subvolumes always survive reinstall; they are what make reinstall possible without Secure Boot Setup Mode or re-enrollment:

```text
@sbctl
@iwd
@tailscale
@netbird
```

`@home` is preserved by default but is a runtime choice: the user may instead choose to recreate it (erasing all user data). When recreation is chosen, `@home` is deleted outright like the rest of the recreate set after its own explicit typed confirmation — no retained copy; a chosen wipe means the data is actually gone. Preflight still requires `@home` to exist either way; its presence is part of the installer-layout fingerprint.

## Fixed Recreate Set

These Btrfs subvolumes are replaced. `@` is renamed aside and retained until the reinstall succeeds (matching the root-replacement `@old-*` pattern); the others are deleted and recreated. `@home` joins this set only when the user chooses to erase it:

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
@portables
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
- [x] Do not add `git`; V2 should not require cloning the installer during rescue.
- [x] Do not add `mkosi`, `archiso`, or `openssl`; those are build-time tools, not rescue reinstall runtime tools.
- [x] Confirm `mkosi -C rescue-uki --no-pager summary` still succeeds.

## Phase 2: Rescue Installer Payload

V2 needs more than the current `rescue-root` script. It needs package lists, static settings, and shared installer logic available inside the rescue image.

- [x] Choose rescue payload path: `/usr/local/share/arch-new-install`.
- [x] Update `rescue-uki/build.sh` to copy the required payload into `rescue-uki/mkosi.extra/usr/local/share/arch-new-install` before `mkosi build`.
- [x] Update `rescue-uki/build.sh` cleanup to remove the copied payload on exit.
- [x] Copy `packages/` into the payload.
- [x] Copy `settings/` into the payload.
- [x] Copy `installer-common.bash` into the payload after it exists.
- [x] Write a payload version file (UTC build date plus git revision) into the payload so the reinstall action can print how old its embedded packages/settings are.
- [x] Copy only files required for rescue reinstall; do not embed `.git`, ISO outputs, or mkosi outputs.
- [x] Keep the existing temporary copy of `rescue-root` as `/usr/local/bin/rescue-root`.

## Phase 3: Shared Installer Code

Create a shared Bash file:

```text
installer-common.bash
```

`common` means the code is shared by the USB installer and the rescue reinstall path.

Refactor discipline: every move in this phase is a verbatim cut-and-paste whose correctness is reviewable from the diff alone. No behavior changes, renames, or improvements mixed into move commits. Watch `set -e` semantics: a function moved from a top-level call site to a conditional call site (or vice versa) changes error behavior.

- [x] Move `BTRFS_MOUNT_OPTIONS` into `installer-common.bash`.
- [x] Move `BTRFS_SUBVOLUMES` into `installer-common.bash`.
- [x] Move `BTRFS_SUBVOLUME_MOUNTS` into `installer-common.bash`.
- [x] Add `BTRFS_PRESERVE_SUBVOLUMES` for the always-preserve set (`@sbctl @iwd @tailscale @netbird`); `@home` is not in either fixed set because it is the only runtime choice, and reinstall logic handles it explicitly.
- [x] Add `BTRFS_RECREATE_SUBVOLUMES` for the fixed recreate set.
- [x] Move `partition_path` into `installer-common.bash`.
- [x] Move `have_network` into `installer-common.bash`; the reinstall preflight uses it.
- [x] Move package-file collection into `installer-common.bash`.
- [x] Move package-name validation into `installer-common.bash`.
- [x] Keep deferred `snap-pac` validation behavior in shared package validation.
- [x] Move `target_chroot` into `installer-common.bash`.
- [x] Move settings copy helpers into `installer-common.bash`.
- [x] Move `append_unique_lines` into `installer-common.bash`.
- [x] Move systemd enable/mask helpers into `installer-common.bash`.
- [x] Move EFI boot-entry deletion by exact label into `installer-common.bash`.
- [x] Move optional EFI/NVRAM cleanup prompt into `installer-common.bash`.
- [x] Move UKI/fwupd signing helpers into `installer-common.bash`, including the JSON signature-verification helper (`sbctl --json verify` + `jq` in the target); plain `sbctl verify` exits 0 even for unsigned files, so the JSON check is the only enforceable verification. This is the one deliberate behavior change in Campaign 1: `install.bash` now enforces verification after every signing.
- [x] Move GPU detection into `installer-common.bash`.
- [x] Move microcode detection into `installer-common.bash`.

## Phase 4: Keep Fresh Install Behavior Unchanged

After adding `installer-common.bash`, refactor `install.bash` to source it without changing fresh install behavior.

- [x] Source `installer-common.bash` from `install.bash`.
- [x] Remove duplicated constants from `install.bash`.
- [x] Replace duplicated helper functions in `install.bash` with shared functions.
- [x] Keep fresh install disk partitioning exactly as-is.
- [x] Keep fresh install ESP formatting exactly as-is.
- [x] Keep fresh install LUKS creation exactly as-is.
- [x] Keep fresh install Secure Boot key creation/enrollment exactly as-is.
- [x] Keep fresh install `Linux Boot Manager` EFI entry behavior exactly as-is.
- [x] Keep fresh install `fwupd` config/signing exactly as-is (signing now also verified via the shared JSON helper).
- [x] Run syntax/static checks before adding the rescue reinstall action.
- [x] HARD CHECKPOINT: build the full ISO and perform a fresh install on real hardware to prove the refactor before any Phase 5 work begins. Campaign 1 ends here and is independently valuable; stop here if rushed.

## Phase 5: Add Rescue Reinstall Menu Action

Add a new action to `iso/airootfs/usr/local/bin/rescue-root`:

```text
Reinstall OS preserving selected state
```

- [x] Resolve the payload path for both environments — `/usr/local/share/arch-new-install` inside the rescue UKI, `/root/arch-new-install` on the live ISO — then source `installer-common.bash` from it.
- [x] Print the payload version (build date) at the start of the reinstall action so running from a stale embedded payload is a conscious choice.
- [x] Keep the existing `Repair installed system` action unchanged.
- [x] Keep the existing `Restore root from snapshot` action unchanged.
- [x] Keep the existing `Check package integrity` action unchanged.
- [x] Add `reinstall_preserving_state` as the implementation function for the new action.
- [x] Fail clearly if the shared installer payload is missing.

## Phase 6: Reinstall Preflight

The reinstall action supports only systems created by this installer.

- [x] Select installed disk with the existing disk selector.
- [x] Treat partition 1 as ESP.
- [x] Treat partition 2 as root.
- [x] Require partition 2 to be LUKS.
- [x] Unlock the existing LUKS root.
- [x] Mount the Btrfs top-level volume at `/mnt` with `subvolid=5`.
- [x] Require every preserve-set subvolume and `@home` to exist; hard-fail otherwise (absence means this is not a system created by this installer). This holds even when the user will choose to erase `@home`.
- [x] Tolerate missing recreate-set subvolumes; they are simply created.
- [x] Verify `@sbctl` contains usable `sbctl` key material.
- [x] Verify the ESP partition can be mounted.
- [x] Confirm network reachability with the installer's `have_network` check before any destructive action.
- [x] Refresh `archlinux-keyring` in the rescue environment before any destructive action; the rescue UKI keyring is frozen at build time and a stale keyring is the most likely pacstrap failure.
- [x] Verify package names before retiring/recreating any subvolumes.
- [x] Show the effective preserve and recreate sets as resolved by the `@home` choice, so the confirmation screen states exactly what survives and what is destroyed.
- [x] Require explicit confirmation before retiring or deleting any subvolumes.

## Phase 7: Reinstall Prompts

Ask only for values needed to regenerate the new root system.

- [x] Ask for hostname.
- [x] Ask for timezone.
- [x] Ask for username.
- [x] Ask for user password.
- [x] Ask whether to preserve `@home` (default) or recreate it. Recreation requires a separate typed confirmation (e.g. typing `ERASE`) because it destroys user data with no retained copy.
- [x] Detect the enrolled unlock method from the LUKS2 header (`cryptsetup luksDump` token types `systemd-tpm2` / `systemd-fido2`; neither present means passphrase-only) instead of asking.
- [x] If exactly one method is detected, ask only for confirmation; never offer a free choice that can contradict the header. If multiple token types are enrolled, choose among the detected ones only.
- [x] Hard-fail with a clear message if the header cannot be read; a wrong `crypttab.initramfs` on a token-only system is unbootable.
- [x] Do not run `systemd-cryptenroll`.
- [x] Do not wipe LUKS password slots.
- [x] Do not create new LUKS credentials.

## Phase 8: Retire And Recreate Subvolumes

The Btrfs layout uses sibling subvolumes, but `@snapshots` contains child snapshot subvolumes. Delete child subvolumes first.

`@` itself is never deleted during reinstall: it is renamed aside so a mid-reinstall failure (network loss during pacstrap, mirror outage) leaves the previous root intact instead of leaving the disk with no OS. Retirement plus recreation is cheap; only the retained old root's disk usage is the cost, and it is reclaimed after verification.

- [x] Rename `@` to `@old-reinstall-<timestamp>` with `mv -T`; hard-fail if the name already exists.
- [x] Build a helper that deletes a Btrfs subvolume tree child-first.
- [x] Use `btrfs subvolume list` to find child subvolumes under each recreate-set subvolume (snapshots under `@snapshots`; container-created subvolumes are possible under `@docker`/`@containers`).
- [x] Delete child subvolumes before deleting their parent.
- [x] Delete each remaining recreate-set subvolume.
- [x] When the user chose to erase `@home`, delete and recreate it exactly like the rest of the recreate set (child-first); when preserving, never touch it.
- [x] Recreate each recreate-set subvolume, including a fresh `@`.
- [x] Do not delete preserve-set subvolumes.
- [x] Do not delete unknown subvolumes outside the fixed recreate set, including `@old-reinstall-*` retained from earlier attempts.
- [x] Set the Btrfs default subvolume to the new `@` if needed.
- [x] Retain `@old-reinstall-<timestamp>` after success; print deletion instructions like the root-replacement action does.

## Phase 9: Mount Target Layout

- [x] Unmount the top-level mount.
- [x] Mount new `@` at `/mnt`.
- [x] Mount recreated sibling subvolumes at their target paths.
- [x] Mount `@home` (preserved or freshly recreated) at `/mnt/home`.
- [x] Mount preserved `@sbctl` at `/mnt/var/lib/sbctl`.
- [x] Mount preserved `@iwd` at `/mnt/var/lib/iwd`.
- [x] Mount preserved `@tailscale` at `/mnt/var/lib/tailscale`.
- [x] Mount preserved `@netbird` at `/mnt/var/lib/netbird`.
- [x] Mount the existing ESP at `/mnt/efi`.
- [x] Apply required permissions for `/mnt/root` and `/mnt/var/tmp`.

## Phase 10: Reinstall Base System And Packages

- [x] Detect CPU microcode.
- [x] Run `pacstrap -K /mnt base base-devel linux linux-headers "$microcode" linux-firmware`.
- [x] Generate `/mnt/etc/fstab` with `genfstab -U /mnt`.
- [x] Install selected package files from the embedded rescue payload.
- [x] Keep `snap-pac` deferred until after Snapper is configured.
- [x] Do not install Docker packages; container subvolumes are storage boundaries only.

## Phase 11: Regenerate Target Configuration

Split target configuration so reinstall can reuse normal installer behavior without running fresh-install-only steps.

- [x] Generate `/etc/hostname`.
- [x] Generate `/etc/hosts`.
- [x] Generate locale config.
- [x] Generate vconsole config.
- [x] Generate timezone symlink.
- [x] Generate `/etc/crypttab.initramfs` from the detected unlock method with the exact option set the fresh installer uses, including `discard`.
- [x] Generate `/etc/cmdline.d/root.conf` with `root=/dev/mapper/cryptroot`.
- [x] Install `/etc/mkinitcpio.conf` from the encrypted variant.
- [x] Install `/etc/mkinitcpio.d/linux.preset`.
- [x] Install static settings from the embedded rescue payload.
- [x] Install `fwupd` config with `DisableShimForSecureBoot=true`.
- [x] Configure services like the normal installer; the current set includes `fstrim.timer` and `systemd-boot-update.service`, and the shared refactor should keep the enable list in one place so both paths cannot drift.
- [x] Preserve existing iwd state by mounting `@iwd`; do not overwrite it with rescue Wi-Fi credentials.
- [x] Create or update the requested user account.
- [x] Create the user with UID/GID 1000 (matches the fresh installer; when `@home` is preserved this keeps existing ownership correct), and verify ownership of `/home/$username` after creation.
- [x] On the preserve path, handle an existing `/home/$username` directory without deleting it; on the erase path, `useradd -m` populates a fresh skeleton home.
- [x] Set the requested user password.
- [x] Lock the root account.

## Phase 12: Snapper And Pacman Hooks

- [x] Configure Snapper for the new `@` root.
- [x] Mount recreated `@snapshots` at `/.snapshots`.
- [x] Keep Snapper cleanup disabled.
- [x] Install `snap-pac` only after Snapper is configured.
- [x] Accept that previous Snapper snapshots are deleted because `@snapshots` is in the recreate set.

## Phase 13: Boot Files And Secure Boot

- [x] Rebuild UKIs with `mkinitcpio -P`.
- [x] Keep existing `/efi/EFI/Linux/arch-rescue.efi` unless V2 explicitly embeds a replacement rescue UKI artifact.
- [x] Sign `/efi/EFI/Linux/arch-linux.efi` with preserved `@sbctl` keys.
- [x] Sign `/efi/EFI/Linux/arch-rescue.efi` when present.
- [x] Sign `/usr/lib/systemd/boot/efi/systemd-bootx64.efi` to `/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed` with preserved `@sbctl` keys.
- [x] Install systemd-boot files with `bootctl --esp-path=/efi --variables=no install`.
- [x] Sign `/efi/EFI/systemd/systemd-bootx64.efi` and `/efi/EFI/BOOT/BOOTX64.EFI`.
- [x] Sign `/usr/lib/fwupd/efi/fwupdx64.efi` to `/usr/lib/fwupd/efi/fwupdx64.efi.signed`.
- [x] Verify every signed artifact with the shared JSON verification helper; do not rely on bare `sbctl verify`, whose exit code is 0 even for unsigned or missing files.
- [x] Delete existing `arch-linux` firmware entries by exact label (legacy direct-EFISTUB installs).
- [x] Delete existing `arch-rescue` firmware entries by exact label (legacy direct-EFISTUB installs).
- [x] Delete existing `Linux Boot Manager` firmware entries by exact label.
- [x] Recreate the `Linux Boot Manager` firmware entry.
- [x] Do not call `sbctl create-keys`.
- [x] Do not call `sbctl enroll-keys`.

## Phase 14: Cleanup And Exit

- [x] Remove temporary sudoers files if any were created.
- [x] Unmount `/mnt` recursively.
- [x] Close `/dev/mapper/cryptroot`.
- [x] Offer to reboot.
- [x] Print clear manual cleanup instructions if unmount or close fails.
- [x] On every failure path after root retirement, state that the previous root is retained as `@old-reinstall-<timestamp>` and that re-running the reinstall action is safe.

## Phase 15: Documentation

Update `README.md` only after the behavior exists; it remains the source of truth for current behavior.

- [x] Document the reinstall action, its preserve/recreate sets, the optional `@home` erase (no retained copy), and when to choose it over rollback, root replacement, or a fresh install.
- [x] Document that the embedded payload is frozen at ISO build time and that the action prints its build date; rebuilding the ISO refreshes it.
- [x] Document that SSH host keys regenerate on reinstall, so remote clients will see host-key-changed warnings; this is expected, not an attack.
- [x] Document retained `@old-reinstall-<timestamp>` deletion, matching the existing `@old-<timestamp>` instructions.

## Phase 16: Validation Commands

Run after each significant phase:

```bash
bash -n install.bash installer-common.bash iso/build.sh rescue-uki/build.sh rescue-uki/mkosi.finalize rescue-uki/mkosi.postinst.chroot rescue-uki/mkosi.version iso/airootfs/usr/local/bin/rescue-root iso/airootfs/usr/local/bin/install-arch settings/rollback/usr/local/sbin/rollback-root settings/network/usr/local/sbin/firewall-profile
```

```bash
shellcheck -x install.bash installer-common.bash iso/build.sh rescue-uki/build.sh rescue-uki/mkosi.finalize rescue-uki/mkosi.postinst.chroot rescue-uki/mkosi.version iso/airootfs/usr/local/bin/rescue-root iso/airootfs/usr/local/bin/install-arch settings/rollback/usr/local/sbin/rollback-root settings/network/usr/local/sbin/firewall-profile
```

`shellcheck -x` follows the `source` of `installer-common.bash` for cross-file analysis.

```bash
git diff --check
```

Run when package/image changes are made:

```bash
mkosi -C rescue-uki --no-pager summary
```

Do not run the full ISO build during routine implementation unless explicitly requested (the Campaign 1 hard checkpoint is the deliberate exception):

```bash
sudo ./iso/build.sh
```

## Phase 17: Test Matrix

- [ ] Fresh USB installer still passes scripted checks.
- [ ] Current rescue manual mount action still works.
- [ ] Current rescue root replacement action still works.
- [ ] Rescue UKI still builds.
- [ ] Custom ISO still builds.
- [ ] Fresh install works on hardware.
- [ ] `arch-rescue` boot works on hardware.
- [ ] Rescue reinstall works with passphrase-only unlock config.
- [ ] Rescue reinstall works with FIDO2 + PIN unlock config.
- [ ] Rescue reinstall works with TPM2 + PIN unlock config on TPM2 hardware.
- [ ] Reinstall preflight aborts before any destructive action when the network check, keyring refresh, or package validation fails.
- [ ] A mid-reinstall failure (e.g., interrupted pacstrap) retains `@old-reinstall-*` and a re-run of the action succeeds.
- [ ] Preserved `@home` remains mounted and user data remains present after reinstall.
- [ ] Preserved `@home` ownership (UID/GID 1000) is correct after reinstall.
- [ ] Reinstall with the `@home` erase choice produces a fresh empty home, requires the typed confirmation, and boots normally.
- [ ] Preserved `@sbctl` signs new UKIs after reinstall.
- [ ] Preserved `@iwd` Wi-Fi profiles remain present after reinstall.
- [ ] Normal boot works after reinstall.
- [ ] Secure Boot verification succeeds after reinstall.
- [ ] Firmware entries contain `Linux Boot Manager` after reinstall.

## Implementation Order

Two campaigns with a hard checkpoint between them. Campaign 1 is independently valuable; stop after it if rushed, and start Campaign 2 only after the checkpoint passes. Use small commits.

Campaign 1 — shared-code refactor, no new behavior:

1. Add rescue UKI runtime packages.
2. Add `installer-common.bash` with shared constants only.
3. Move low-risk shared helpers into `installer-common.bash` as verbatim cut-and-paste commits.
4. Refactor `install.bash` to use shared helpers with no behavior change.
5. HARD CHECKPOINT: full ISO build plus a fresh install on real hardware.

Campaign 2 — reinstall feature:

6. Embed the rescue installer payload with its payload version file.
7. Add the third `rescue-root` menu action with preflight only.
8. Add root retirement (`@old-reinstall-*`) and subvolume recreation.
9. Add reinstall package/config generation.
10. Add UKI signing/verification and firmware entry recreation.
11. Test on hardware.
