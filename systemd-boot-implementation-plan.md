# systemd-boot Implementation Plan

Status: proposal only. The installer still uses direct EFISTUB UKI boot unless this plan is explicitly approved and implemented.

This document describes the simplest possible migration from direct EFISTUB UKI boot to `systemd-boot`, while preserving the current installer policy:

- Mandatory LUKS root.
- Mandatory Secure Boot with `sbctl`.
- Mandatory `lockdown=integrity`.
- Signed UKIs.
- No GRUB.
- No shim-managed workflow.
- No `ukify` migration.
- No `kernel-install` migration.
- No XBOOTLDR partition.
- No Type #1 loader entries for the normal Arch system.

The intended design keeps the current UKI model and adds only a signed `systemd-boot` menu in front of it.

## Decision Summary

The current boot chain is:

```text
firmware -> signed arch-linux.efi
firmware -> signed arch-rescue.efi
```

The proposed boot chain is:

```text
firmware -> signed systemd-boot -> signed arch-linux.efi
firmware -> signed systemd-boot -> signed arch-rescue.efi
```

The current design has the smallest possible trusted boot chain.

The proposed design adds one signed EFI binary in exchange for a proper boot menu and simpler rescue selection.

## Recommendation If Approved

Use `systemd-boot` only as a signed UEFI boot menu for Type #2 UKIs.

Do not use classic Type #1 loader entries.

Do not create files like:

```text
/efi/loader/entries/arch.conf
/efi/loader/entries/arch-rescue.conf
```

Instead, keep the existing UKI locations:

```text
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
```

Let `systemd-boot` auto-discover these UKIs.

## Why Type #2 UKIs

Type #2 UKIs keep the boot-critical payload in a single signed PE executable.

The signed UKI contains:

- EFI stub.
- Kernel.
- Initramfs.
- Kernel command line.
- OS metadata.
- Optional splash and other UKI sections.

This avoids the classic Type #1 pattern where a bootloader reads separate kernel, initramfs, and command-line entries from unsigned text files.

For this repo, Type #2 is also the smallest change because the installer already builds:

```text
/efi/EFI/Linux/arch-linux.efi
```

and already installs:

```text
/efi/EFI/Linux/arch-rescue.efi
```

## Security Notes

Research summary:

- No public high or critical CVE was found that specifically targets `systemd-boot` as the UEFI boot manager.
- The main upstream `systemd-boot`-specific advisory found was `GHSA-6m6p-rjcq-334c`.
- That advisory was low severity, CVSS 1.7, no CVE ID.
- It affected `arm64` and `riscv64` Secure Boot systems using Type #1 BLS entries.
- The proposed design is `x86_64` with Type #2 UKIs, so that issue does not match the intended layout.
- Some vulnerability databases list unrelated `systemd` CVEs under `systemd-boot-unsigned` because distro packages are built from the same source package.
- Examples of unrelated CVEs checked: `CVE-2023-7008` for `systemd-resolved`, `CVE-2025-4598` for `systemd-coredump`, and `CVE-2026-29111` for PID 1 IPC behavior.

Relative attack surface:

```text
direct EFISTUB signed UKI     smallest chain
systemd-boot + signed UKIs    small chain with boot menu
GRUB/shim stack               much larger and unnecessary here
```

The proposed setup is not more minimal than direct EFISTUB. It is more convenient.

The proposed setup is substantially simpler than GRUB because `systemd-boot` is UEFI-only, does not provide a GRUB-like shell, does not use GRUB-style scripting, and can boot signed UKIs directly.

## Target ESP Layout

The target ESP remains mounted at:

```text
/efi
```

The target ESP layout becomes:

```text
/efi/EFI/systemd/systemd-bootx64.efi
/efi/EFI/BOOT/BOOTX64.EFI
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
/efi/loader/loader.conf
/efi/loader/random-seed
```

The current direct EFISTUB firmware entries are removed:

```text
arch-linux
arch-rescue
```

The proposed firmware entry is:

```text
Linux Boot Manager -> \EFI\systemd\systemd-bootx64.efi
```

`bootctl install` normally creates this entry itself, but the installer should not rely on that from a normal `arch-chroot` environment. The robust approach is to install bootloader files with `bootctl --variables=no` and keep using `efibootmgr` for the single NVRAM entry.

## Loader Configuration

Add a new settings file:

```text
settings/boot/efi/loader/loader.conf
```

Recommended content:

```ini
default arch-linux.efi
timeout 3
console-mode max
editor no
```

Explanation:

- `default arch-linux.efi` makes the normal Arch UKI the default boot target.
- `timeout 3` gives enough time to select rescue without slowing normal boots much.
- `console-mode max` keeps the menu readable on high-resolution firmware consoles.
- `editor no` disables interactive kernel command-line editing from the boot menu.

Do not add:

```ini
secure-boot-enroll force
```

Reason: this repo uses `sbctl` for Secure Boot keys. Mixing systemd's auto-enrollment workflow with `sbctl` would add a second key-management path.

## Package Changes

No new target package should be required for `systemd-boot` itself.

Reason: `systemd-boot` ships with the `systemd` package, and `systemd` is already part of the installed base system.

Keep `efibootmgr` in `packages/base.conf`.

Reason: the installer should continue to manage firmware entries explicitly and predictably.

Keep `sbctl` in `packages/base.conf`.

Reason: `sbctl` remains the only Secure Boot key and signing tool.

## Signing Model

The installer should sign four boot-critical files:

```text
/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed
/efi/EFI/systemd/systemd-bootx64.efi
/efi/EFI/BOOT/BOOTX64.EFI
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
```

The first path is a signed source copy:

```text
/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed
```

`bootctl install` and `bootctl update` prefer the `.efi.signed` file when it exists.

This is important because `systemd-boot` updates are copied from `/usr/lib/systemd/boot/efi/` to the ESP. Signing only the ESP copy is not enough for clean future updates.

The installer should run:

```bash
sbctl sign -s \
    -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
    /usr/lib/systemd/boot/efi/systemd-bootx64.efi
```

Then install the bootloader files:

```bash
bootctl --esp-path=/efi --variables=no install
```

Then sign the installed ESP copies if `sbctl verify` reports them unsigned, or sign explicitly for clarity:

```bash
sbctl sign -s /efi/EFI/systemd/systemd-bootx64.efi
sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI
```

The explicit ESP signing is slightly redundant when `bootctl` correctly copied the `.signed` file, but it makes verification deterministic and protects against behavior changes.

Then sign the UKIs:

```bash
sbctl sign -s /efi/EFI/Linux/arch-linux.efi
sbctl sign -s /efi/EFI/Linux/arch-rescue.efi
```

Then verify:

```bash
sbctl verify
```

## Update Model

Arch currently updates installed `systemd-boot` copies automatically when the `systemd` package detects an installed bootloader and runs the marked update service after package upgrades.

The simple plan is:

- Do not add a custom pacman hook initially.
- Let Arch/systemd manage `systemd-boot` updates.
- Register the signed `/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed` output with `sbctl -s`.
- Confirm in VM that `sbctl` re-signs the source `.signed` output after a `systemd` package upgrade.
- Confirm in VM that `bootctl update` copies the signed file to the ESP.

If VM testing shows the `sbctl` database does not preserve the input-to-output signing mapping reliably, add one small pacman hook later.

Do not add the hook unless testing proves it is needed.

## Installer Changes

### Header Text

Current header says:

```text
Niri-only Btrfs + UKI + EFISTUB
```

If approved, change it to:

```text
Niri-only Btrfs + UKI + systemd-boot
```

### Preflight Dependencies

Keep `efibootmgr` in the live dependency check.

Do not add a live `bootctl` dependency unless the installer starts calling `bootctl` outside the target chroot.

The target chroot has `bootctl` through `systemd`.

### Directory Creation

Current code creates:

```bash
install -d -m 0755 /mnt/boot /mnt/efi/EFI/Linux /mnt/etc/cmdline.d /mnt/etc/mkinitcpio.d
```

If approved, change this to include the loader directory:

```bash
install -d -m 0755 \
    /mnt/boot \
    /mnt/efi/EFI/Linux \
    /mnt/efi/loader \
    /mnt/etc/cmdline.d \
    /mnt/etc/mkinitcpio.d
```

Then copy loader config:

```bash
copy_settings_file boot /efi/loader/loader.conf
```

### UKI Generation

Keep the current mkinitcpio preset:

```text
settings/boot/etc/mkinitcpio.d/linux.preset
```

Current content:

```bash
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default')
default_uki="/efi/EFI/Linux/arch-linux.efi"
default_options="--splash=/usr/share/systemd/bootctl/splash-arch.bmp"
```

No change is required.

Reason: systemd-boot auto-discovers UKIs in `/EFI/Linux/`.

### Firmware Entry Management

Current EFISTUB flow deletes and recreates two entries:

```bash
delete_boot_entries_by_label "arch-linux"
delete_boot_entries_by_label "arch-rescue"
efibootmgr --create ... --label "arch-rescue" --loader "\\EFI\\Linux\\arch-rescue.efi"
efibootmgr --create ... --label "arch-linux" --loader "\\EFI\\Linux\\arch-linux.efi"
```

Replace this with one boot manager entry:

```bash
delete_boot_entries_by_label "arch-linux"
delete_boot_entries_by_label "arch-rescue"
delete_boot_entries_by_label "Linux Boot Manager"
efibootmgr --create \
    --disk "$target_disk" \
    --part 1 \
    --label "Linux Boot Manager" \
    --loader "\\EFI\\systemd\\systemd-bootx64.efi" \
    --unicode
```

The `delete_boot_entries_by_label "Linux Boot Manager"` step avoids accumulating duplicate boot manager entries across reinstall attempts.

### Bootloader Install Placement

The bootloader cannot be installed before Secure Boot keys exist if we want the first copied bootloader to be signed.

The clean placement is inside the current `sbctl` block after keys are created and enrolled.

Current block:

```bash
if target_chroot sbctl status | grep -q 'Setup Mode:.*Enabled'; then
    target_chroot sbctl create-keys
    target_chroot sbctl enroll-keys -m
    target_chroot sbctl sign -s /efi/EFI/Linux/arch-linux.efi
    target_chroot sbctl sign -s "$RESCUE_UKI_TARGET"
    ...
    target_chroot sbctl verify
fi
```

Proposed block:

```bash
if target_chroot sbctl status | grep -q 'Setup Mode:.*Enabled'; then
    target_chroot sbctl create-keys
    target_chroot sbctl enroll-keys -m

    target_chroot sbctl sign -s \
        -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
        /usr/lib/systemd/boot/efi/systemd-bootx64.efi

    target_chroot bootctl --esp-path=/efi --variables=no install

    target_chroot sbctl sign -s /efi/EFI/systemd/systemd-bootx64.efi
    target_chroot sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI
    target_chroot sbctl sign -s /efi/EFI/Linux/arch-linux.efi
    target_chroot sbctl sign -s "$RESCUE_UKI_TARGET"

    if [[ -f /mnt/usr/lib/fwupd/efi/fwupdx64.efi ]]; then
        target_chroot sbctl sign -s -o /usr/lib/fwupd/efi/fwupdx64.efi.signed /usr/lib/fwupd/efi/fwupdx64.efi
    fi

    target_chroot sbctl verify
    target_chroot sbctl status || true
else
    show_error "Secure Boot is not in setup mode"
    exit 1
fi
```

Then create the NVRAM entry after `bootctl install` has copied the files:

```bash
delete_boot_entries_by_label "arch-linux"
delete_boot_entries_by_label "arch-rescue"
delete_boot_entries_by_label "Linux Boot Manager"
target_chroot efibootmgr --create \
    --disk "$target_disk" \
    --part 1 \
    --label "Linux Boot Manager" \
    --loader "\\EFI\\systemd\\systemd-bootx64.efi" \
    --unicode
```

This can be placed immediately after `bootctl install` or immediately after the signing/verify block.

Preferred placement: after `bootctl install` and before `sbctl verify`, so verification sees the installed ESP files before the boot entry is created.

### Why Not Plain `bootctl install`

ArchWiki notes that `bootctl install` may avoid touching EFI variables from a normal `arch-chroot` environment because of PID namespace behavior.

The current installer already has working `efibootmgr` logic.

Therefore, the least surprising installer behavior is:

```bash
bootctl --esp-path=/efi --variables=no install
efibootmgr --create --label "Linux Boot Manager" ...
```

This keeps bootloader file installation and firmware entry creation explicit.

## Rescue UKI Impact

The rescue UKI remains:

```text
/efi/EFI/Linux/arch-rescue.efi
```

The user selects rescue from the `systemd-boot` menu instead of firmware boot entries.

This is operationally simpler because firmware only needs one boot entry.

The installed `arch-rescue` NVRAM entry is removed from the design.

Rescue root replacement remains conceptually unchanged.

Manual repair remains conceptually unchanged.

Rescue V2 reinstall becomes simpler because it recreates one firmware entry instead of two.

## Rescue Reinstall Plan Updates If Approved

If this migration is approved, update `rescue-reinstall-implementation-plan.md`:

- Replace references to direct firmware entries for `arch-linux` and `arch-rescue`.
- Preserve the fixed policy as `signed systemd-boot + signed UKIs` instead of direct UKI EFISTUB.
- Reinstall flow should restore `/efi/EFI/Linux/arch-linux.efi`.
- Reinstall flow should preserve or restore `/efi/EFI/Linux/arch-rescue.efi`.
- Reinstall flow should install signed `systemd-boot` files.
- Reinstall flow should recreate only `Linux Boot Manager`.

## README Updates If Approved

Update current behavior documentation:

- Replace `direct UKI boot` wording with `systemd-boot with signed UKIs`.
- Remove `No systemd-boot` from the feature list.
- Replace firmware entry section with one `Linux Boot Manager` entry.
- Explain that rescue is selected from the `systemd-boot` menu.
- Update troubleshooting commands to include `bootctl`.
- Keep Secure Boot, LUKS, Snapper, and rescue UKI behavior unchanged.

## Commands For Manual Inspection After Install

After booting the installed system:

```bash
bootctl status
bootctl list
sbctl status
sbctl verify
efibootmgr --unicode
```

Expected `bootctl list` entries:

```text
arch-linux.efi
arch-rescue.efi
```

Expected firmware entry:

```text
Linux Boot Manager
```

Expected absent firmware entries:

```text
arch-linux
arch-rescue
```

Expected signed files:

```text
/efi/EFI/systemd/systemd-bootx64.efi
/efi/EFI/BOOT/BOOTX64.EFI
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed
```

## Validation Commands During Development

Static checks:

```bash
bash -n install.bash iso/build.sh rescue-uki/build.sh rescue-uki/mkosi.finalize rescue-uki/mkosi.postinst.chroot rescue-uki/mkosi.version iso/airootfs/usr/local/bin/rescue-root iso/airootfs/usr/local/bin/install-arch settings/rollback/usr/local/sbin/rollback-root
```

Shellcheck:

```bash
shellcheck install.bash iso/build.sh rescue-uki/build.sh rescue-uki/mkosi.finalize rescue-uki/mkosi.postinst.chroot rescue-uki/mkosi.version iso/airootfs/usr/local/bin/rescue-root iso/airootfs/usr/local/bin/install-arch settings/rollback/usr/local/sbin/rollback-root
```

Whitespace check:

```bash
git diff --check
```

Rescue UKI summary:

```bash
mkosi -C rescue-uki --no-pager summary
```

ISO build:

```bash
sudo ./iso/build.sh
```

## VM Test Matrix

Fresh install tests:

- Install with passphrase-only LUKS unlock.
- Install with TPM2 + PIN when TPM is available in VM or hardware test system.
- Install with FIDO2 + PIN on hardware if available.
- Confirm `systemd-boot` menu appears.
- Confirm default entry boots normal Arch.
- Confirm rescue entry boots `arch-rescue`.
- Confirm Secure Boot remains enabled after firmware keys are enrolled.
- Confirm kernel reports Secure Boot enabled.
- Confirm kernel command line includes `lockdown=integrity`.
- Confirm root unlock works.
- Confirm Snapper rollback helper still works.

Firmware entry tests:

- Confirm exactly one `Linux Boot Manager` entry is created for this install.
- Confirm old `arch-linux` entries are deleted.
- Confirm old `arch-rescue` entries are deleted.
- Re-run install in the same VM and confirm duplicate `Linux Boot Manager` entries are not accumulated.

Signing tests:

- Confirm `sbctl verify` passes after install.
- Confirm `/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed` exists.
- Confirm ESP `systemd-bootx64.efi` is signed.
- Confirm fallback `BOOTX64.EFI` is signed.
- Confirm both UKIs are signed.
- Confirm fwupd signed output still exists when fwupd provides the EFI binary.

Update tests:

- Run `sudo pacman -Syu` after install.
- If `systemd` updates, confirm `systemd-boot` remains signed.
- Run `bootctl update` manually in a VM and confirm it uses the signed `.efi.signed` source.
- Run `sbctl verify` after the update.
- Reboot after the update and confirm normal boot still works.
- Select rescue after the update and confirm rescue still works.

Negative tests:

- Temporarily remove or rename `/efi/EFI/Linux/arch-rescue.efi` in a VM and confirm normal boot still works.
- Temporarily remove or rename `/efi/EFI/Linux/arch-linux.efi` in a VM and confirm rescue remains selectable.
- Confirm `editor no` prevents interactive command-line editing from the boot menu.

## Rollback Plan To Direct EFISTUB

If `systemd-boot` is implemented and later rejected, rollback is straightforward.

Restore direct firmware entries:

```bash
efibootmgr --create \
    --disk /dev/nvme0n1 \
    --part 1 \
    --label "arch-linux" \
    --loader "\\EFI\\Linux\\arch-linux.efi" \
    --unicode

efibootmgr --create \
    --disk /dev/nvme0n1 \
    --part 1 \
    --label "arch-rescue" \
    --loader "\\EFI\\Linux\\arch-rescue.efi" \
    --unicode
```

Delete `Linux Boot Manager` entry:

```bash
efibootmgr --unicode
efibootmgr --bootnum XXXX --delete-bootnum --unicode
```

Optionally remove `systemd-boot` ESP files:

```bash
rm -rf /efi/EFI/systemd
rm -f /efi/EFI/BOOT/BOOTX64.EFI
rm -rf /efi/loader
```

Do not remove UKIs:

```text
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
```

Those are still the direct EFISTUB boot targets.

## Implementation Phases

### Phase 1: Documentation Decision

- [ ] Read this plan.
- [ ] Decide whether to keep direct EFISTUB or switch to `systemd-boot`.
- [ ] If undecided, leave this file as a parked implementation option.

### Phase 2: Minimal File Additions

- [ ] Add `settings/boot/efi/loader/loader.conf`.
- [ ] Keep mkinitcpio UKI preset unchanged.
- [ ] Keep package lists unchanged unless testing proves otherwise.

### Phase 3: Installer Boot Flow Changes

- [ ] Update installer header text.
- [ ] Create `/mnt/efi/loader`.
- [ ] Copy loader config to `/efi/loader/loader.conf`.
- [ ] Remove direct `arch-linux` NVRAM entry creation.
- [ ] Remove direct `arch-rescue` NVRAM entry creation.
- [ ] Install signed `systemd-boot` with `bootctl --esp-path=/efi --variables=no install`.
- [ ] Create one `Linux Boot Manager` NVRAM entry with `efibootmgr`.
- [ ] Keep UKI generation unchanged.
- [ ] Keep rescue UKI copy unchanged.
- [ ] Keep Secure Boot Setup Mode requirement unchanged.

### Phase 4: Signing Changes

- [ ] Sign `/usr/lib/systemd/boot/efi/systemd-bootx64.efi` to `.efi.signed`.
- [ ] Sign `/efi/EFI/systemd/systemd-bootx64.efi`.
- [ ] Sign `/efi/EFI/BOOT/BOOTX64.EFI`.
- [ ] Sign `/efi/EFI/Linux/arch-linux.efi`.
- [ ] Sign `/efi/EFI/Linux/arch-rescue.efi`.
- [ ] Keep fwupd signing unchanged.
- [ ] Run `sbctl verify`.

### Phase 5: Documentation Updates

- [ ] Update `README.md` current behavior.
- [ ] Update `rescue-reinstall-implementation-plan.md` future V2 assumptions.
- [ ] Remove direct EFISTUB wording from user-facing docs.
- [ ] Keep a note that UKIs remain the boot payloads.

### Phase 6: VM and Hardware Validation

- [ ] Run static checks.
- [ ] Build ISO.
- [ ] Fresh install in VM.
- [ ] Verify boot menu.
- [ ] Verify normal boot.
- [ ] Verify rescue boot.
- [ ] Verify Secure Boot signatures.
- [ ] Verify update behavior.
- [ ] Test on real hardware only after VM path is clean.

## Final Decision Criteria

Stay with direct EFISTUB if the priority is:

- Smallest possible trusted boot chain.
- No boot manager.
- Maximum conceptual simplicity.
- Fewer signed EFI binaries.

Switch to `systemd-boot` if the priority is:

- Simple rescue selection without firmware menus.
- One firmware entry instead of two.
- Easier future reinstall/rescue logic.
- Better operator experience.
- Still-small attack surface compared with GRUB.

Do not switch if it leads to:

- Type #1 loader entries for the normal system.
- `ukify` migration before there is a reason.
- `kernel-install` migration before there is a reason.
- Two Secure Boot enrollment systems.
- Custom update hooks before testing proves they are necessary.

## Preferred Final State If Approved

The final approved design should be exactly this:

```text
ESP: /efi
Boot manager: signed systemd-boot
Boot payloads: signed Type #2 UKIs
Normal UKI: /efi/EFI/Linux/arch-linux.efi
Rescue UKI: /efi/EFI/Linux/arch-rescue.efi
Firmware entry: Linux Boot Manager
Secure Boot keys: sbctl only
Loader entries: none
XBOOTLDR: none
GRUB: none
shim workflow: none
```
