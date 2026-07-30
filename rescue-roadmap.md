# Rescue Roadmap

`README.md` is the source of truth for current installer and rescue behavior.

This file tracks future rescue work that is intentionally not implemented yet.

## V2: Rescue Reinstall

V2 may add a reinstall path that runs from the installed rescue UKI instead of the USB installer.

Goal:

- Freshly reinstall the OS from the rescue environment on an already-owned machine.
- Avoid requiring USB media for routine reinstall/recovery.
- Reuse the machine's existing Secure Boot trust and preserved state.
- Preserve the existing disk partition table, ESP, LUKS container, and Btrfs filesystem.

Non-negotiables:

- Do not enroll Secure Boot keys.
- Do not require firmware Secure Boot Setup Mode.
- Do not repartition the disk.
- Do not reformat the ESP.
- Do not recreate or erase the LUKS container.
- Do not wipe or re-enroll LUKS slots by default.
- Do not duplicate the whole installer in a second large script.
- Do not preserve state implicitly; preservation must be explicit.
- Keep the installed system policy aligned with the normal installer: mandatory LUKS root, mandatory Secure Boot, mandatory `lockdown=integrity`, direct UKIs, and no bootloader.

Preserve set:

```text
@home
@sbctl
@iwd
@tailscale
@netbird
```

Delete and recreate set:

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

Expected model:

1. Boot `arch-rescue`.
2. Unlock the existing LUKS root.
3. Mount the Btrfs top-level volume.
4. Verify the preserved subvolumes exist.
5. Ask for install-time values that live in the root subvolume, such as hostname, timezone, username, and user password.
6. Ask which existing LUKS unlock method should be written into the new system config: passphrase-only, TPM2 + PIN, or FIDO2 + PIN.
7. Move or delete the old reinstall-managed subvolumes.
8. Recreate the installer-managed subvolume layout.
9. Reinstall packages and static settings.
10. Recreate generated files such as `/etc/fstab`, `/etc/crypttab.initramfs`, `/etc/cmdline.d/root.conf`, `/etc/hostname`, `/etc/hosts`, locale config, and user account state.
11. Reuse preserved `@sbctl` keys to sign new UKIs.
12. Recreate `arch-linux` and `arch-rescue` firmware entries.
13. Leave preserved user data, network state, and Secure Boot keys intact.

ESP handling:

- Keep the existing ESP filesystem.
- Replace only installer-owned EFI files as needed:

```text
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
```

- Do not delete unrelated vendor firmware update files or other manually preserved ESP content.
- Keep the optional EFI/NVRAM boot-entry cleanup prompt, and continue deleting/recreating `arch-linux` and `arch-rescue` by exact label.

Secure Boot handling:

- Reuse preserved keys from `@sbctl` mounted at `/var/lib/sbctl`.
- Sign the normal UKI:

```bash
sbctl sign -s /efi/EFI/Linux/arch-linux.efi
```

- Sign the rescue UKI when it is replaced or already present:

```bash
sbctl sign -s /efi/EFI/Linux/arch-rescue.efi
```

- Configure and sign `fwupd` exactly like the normal installer:

```ini
[uefi_capsule]
DisableShimForSecureBoot=true
```

```bash
sbctl sign -s -o /usr/lib/fwupd/efi/fwupdx64.efi.signed /usr/lib/fwupd/efi/fwupdx64.efi
```

Rescue payload requirement:

- The current V1 rescue image only needs `rescue-root` for mount/rollback operations.
- V2 reinstall needs more than that: package lists, static settings, and shared installer logic must be available inside the rescue environment or fetched by an explicit workflow.
- Prefer embedding a minimal installer payload in the rescue UKI when V2 is implemented, rather than relying on a network clone during recovery.

Networking and packages:

- Reinstall still needs package downloads unless V2 introduces a local package cache or repository.
- Network setup must be available before package validation and installation.
- Package validation must happen before deleting/recreating subvolumes.
- `snap-pac` should remain deferred until after Snapper is configured, matching the normal installer.

Likely prerequisite:

```text
installer-lib.bash
```

Shared installer logic would need to move out of `install.bash` so the USB install path and rescue reinstall path can reuse:

- package collection and validation
- pacstrap/package installation helpers
- settings installation
- target configuration
- Snapper setup
- UKI signing
- EFI boot entry management
- Btrfs layout constants
- generated file creation for fstab, crypttab, cmdline, locale, hostname, hosts, and users
- LUKS unlock-method config generation without key enrollment

User interface:

- Prefer adding a third `rescue-root` action named `Reinstall OS preserving selected state`.
- A separate `rescue-reinstall` command is acceptable only as a thin wrapper around shared code.
- Do not create a second independent installer implementation.

Testing requirements:

- Test the normal USB installer first.
- Test the existing V1 rescue mount and root replacement flow first.
- Test V2 in a VM before hardware.
- Test at least passphrase-only and FIDO2 + PIN unlock configs before considering V2 complete.

Do not start V2 until the normal USB installer and V1 rescue flow have been tested successfully on real hardware.
