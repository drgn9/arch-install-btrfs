# Rescue UKI Implementation Plan

This plan implements `rescue-uki-prd.md` V1.

The goal is to integrate a prebuilt rescue UKI into the existing USB ISO and installer flow without changing the current first-time installation behavior beyond automatically installing/signing/registering the rescue UKI.

## Target Architecture

Build machine workflow:

```text
sudo ./iso/build.sh
```

`iso/build.sh` will:

1. Prompt for the rescue root password through the internal rescue UKI helper.
2. Build the rescue UKI with `mkosi`.
3. Delete the temporary `mkosi.rootpw` file automatically.
4. Copy the resulting rescue `.efi` to a stable artifact path.
5. Build the USB ISO.
6. Bake the rescue UKI artifact into the USB ISO.

Install-time workflow:

```text
USB installer boots
install.bash runs current first-time install flow
install.bash copies prebuilt arch-rescue.efi to target ESP
install.bash signs arch-rescue.efi with target sbctl keys
install.bash creates arch-rescue EFI boot entry
```

Rescue-time workflow:

```text
firmware boots /efi/EFI/Linux/arch-rescue.efi
rescue environment starts
user runs rescue-root
existing rescue-root script provides rollback/chroot repair
```

## Non-Negotiables

- Do not replace EFISTUB with `systemd-boot`.
- Do not change the USB ISO into a rescue-only artifact.
- Do not build the rescue UKI inside the target chroot during installation.
- Do not require users to run a separate rescue UKI build command.
- Do not leave `mkosi.rootpw` behind after the build.
- Do not create a duplicate rescue script.
- Reuse the existing `iso/airootfs/usr/local/bin/rescue-root` script.
- Do not implement `rescue-reinstall.bash` in V1.
- Do not embed Secure Boot private keys in the rescue UKI or ISO.
- Keep the current USB install flow intact.

## New Files And Directories

Add:

```text
rescue-uki/
├── build.sh
├── mkosi.conf
├── mkosi.extra/
│   ├── etc/
│   │   ├── motd
│   │   └── systemd/
│   │       └── system-preset/
│   │           ├── 10-rescue-networking.preset
│   │           ├── 10-rescue-disable-unneeded.preset
│   │           └── 10-timesync.preset
│   └── usr/
│       └── local/
│           └── bin/
│               └── rescue-root
├── mkosi.finalize
├── mkosi.postinst.chroot
├── mkosi.version
└── .gitignore
```

Add generated artifact directory:

```text
artifacts/
```

`artifacts/` should contain generated build artifacts and be gitignored.

Expected generated file:

```text
artifacts/arch-rescue.efi
```

## Gitignore Changes

Update project `.gitignore`:

```gitignore
artifacts/
rescue-uki/mkosi.output/
rescue-uki/mkosi.cache/
rescue-uki/mkosi.local/
rescue-uki/mkosi.local.conf
rescue-uki/.mkosi-private/
rescue-uki/mkosi.rootpw
```

Do not ignore `rescue-uki/` itself.

Do not commit generated `.efi` artifacts.

Do not commit `mkosi.rootpw`.

## Rescue UKI Build Script

Create:

```text
rescue-uki/build.sh
```

Responsibilities:

1. Verify it is running on Arch Linux or at least that required tools exist.
2. Ensure build dependencies are installed:

```text
mkosi
systemd-ukify
rsync
```

3. Always prompt for the rescue root password.
4. Prompt for confirmation and fail if the two entries do not match.
5. Hash the password with `openssl passwd -6`.
6. Write `rescue-uki/mkosi.rootpw` with mode `0600`.
7. Install a cleanup trap that always deletes `rescue-uki/mkosi.rootpw` on exit, success, failure, or interrupt.
8. Copy/sync the existing rescue script into the mkosi overlay:

```text
iso/airootfs/usr/local/bin/rescue-root
-> rescue-uki/mkosi.extra/usr/local/bin/rescue-root
```

9. Run:

```bash
mkosi build
```

10. Find exactly one resulting `.efi` UKI in `rescue-uki/mkosi.output/`.
11. Copy it to:

```text
artifacts/arch-rescue.efi
```

12. Print the final artifact path and size.

Important behavior:

- The build script builds only the rescue UKI and is called by `iso/build.sh`.
- It does not install to `/efi` by default in V1.
- It does not sign the artifact by default in V1.
- Signing happens during target installation with target `sbctl` keys.
- It always prompts for a password and never reuses a previous `mkosi.rootpw`.

## mkosi Configuration

Create:

```text
rescue-uki/mkosi.conf
```

Base direction:

```ini
[Output]
ImageId=arch-rescue
Format=uki
CompressOutput=true
SplitArtifacts=uki

[Distribution]
Distribution=arch

[Content]
Bootloader=none
Bootable=false
Hostname=arch-rescue
RootShell=/bin/bash
Keymap=us
Locale=C.UTF-8
MicrocodeHost=true
```

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
util-linux
dosfstools
vim
less
man-pages
mandoc
```

Kernel module policy should follow the rescue-image projects:

```ini
KernelModulesExclude=.*
KernelModulesIncludeHost=true
KernelModulesInclude=
    fs/
    hid/
    input/
    dm-.*
    crypto/
    tpm/
    virtio
```

Removal policy should trim obviously unnecessary files:

```text
/usr/include/
/usr/share/include
/usr/share/pkgconfig
/usr/lib/**/*.a
/usr/share/locale
/var/lib/pacman/sync/*
```

Avoid excessive cleanup initially. Prefer a larger working rescue image over an overly-minimized image that lacks needed libraries.

## mkosi Overlay

Create login message:

```text
rescue-uki/mkosi.extra/etc/motd
```

Suggested content:

```text
Arch rescue UKI.

Run:

    rescue-root

For Wi-Fi setup, run:

    impala

For manual repair, rescue-root can mount the installed system at /mnt.
```

System presets:

```text
10-timesync.preset
10-rescue-networking.preset
10-rescue-disable-unneeded.preset
```

V1 networking preset should enable:

```text
iwd.service
systemd-timesyncd.service
```

If DHCP is not automatic with only `iwd`, add either:

```text
systemd-networkd.service
systemd-resolved.service
```

with simple `.network` files, or document manual network setup. Prefer automatic Ethernet DHCP if it is simple.

## mkosi Hooks

Create:

```text
rescue-uki/mkosi.postinst.chroot
```

Responsibilities:

- update manpage database
- initialize/populate pacman keyring

Expected commands:

```bash
makewhatis /usr/share/man
pacman-key --init
pacman-key --populate
```

Create:

```text
rescue-uki/mkosi.finalize
```

Responsibilities:

- set/finalize `PRETTY_NAME` in `/etc/os-release`
- keep it simple

Create:

```text
rescue-uki/mkosi.version
```

Recommended content:

```bash
#!/usr/bin/bash
printf "r%s.r%s-%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)" "$(date --utc +%Y%m%d%H%M)"
```

## Root Password

The rescue UKI needs a root password.

The user must not manually create the password file.

During:

```bash
sudo ./iso/build.sh
```

the internal rescue UKI helper must:

1. Ask for the rescue root password.
2. Ask for confirmation.
3. Hash the password.
4. Write `rescue-uki/mkosi.rootpw` temporarily.
5. Build the rescue UKI.
6. Delete `rescue-uki/mkosi.rootpw` automatically.

Autologin is not part of V1.

## ISO Build Integration

Modify:

```text
iso/build.sh
```

Current flow:

```text
assemble archiso profile
copy repo into ISO
install launchers
mkarchiso
```

New flow:

```text
build rescue UKI first
verify artifacts/arch-rescue.efi exists
assemble archiso profile
copy repo into ISO
install launchers
mkarchiso
```

Implementation detail:

```bash
"$REPO_DIR/rescue-uki/build.sh"
[[ -f "$REPO_DIR/artifacts/arch-rescue.efi" ]] || exit 1
```

Because `artifacts/` will be gitignored, the existing `rsync --filter=':- .gitignore'` would exclude it when copying the repo into the ISO.

Therefore `iso/build.sh` must explicitly copy the generated rescue artifact into the ISO after the repo sync.

Preferred ISO path:

```text
/root/arch-new-install/artifacts/arch-rescue.efi
```

Example:

```bash
install -D -m 0644 "$REPO_DIR/artifacts/arch-rescue.efi" \
    "$PROFILE_DIR/airootfs/root/arch-new-install/artifacts/arch-rescue.efi"
```

This keeps generated artifacts out of Git while still baking the artifact into the ISO.

## Installer Integration

Modify:

```text
install.bash
```

Add constant:

```bash
RESCUE_UKI_SOURCE="$SCRIPT_DIR/artifacts/arch-rescue.efi"
RESCUE_UKI_TARGET=/efi/EFI/Linux/arch-rescue.efi
```

Add preflight check before destructive disk work:

```bash
[[ -f "$RESCUE_UKI_SOURCE" ]] || fail clearly
```

This prevents a first-time install from silently omitting the rescue UKI.

Copy rescue UKI after ESP mount and before signing:

```bash
install -D -m 0644 "$RESCUE_UKI_SOURCE" "/mnt$RESCUE_UKI_TARGET"
```

Sign rescue UKI in the existing Secure Boot signing block:

```bash
target_chroot sbctl sign -s "$RESCUE_UKI_TARGET"
```

Sign order:

```text
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
optional fwupd binary
```

Add rescue boot entry after normal entries:

```bash
delete_boot_entries_by_label "arch-rescue"
target_chroot efibootmgr --create \
    --disk "$target_disk" \
    --part 1 \
    --label "arch-rescue" \
    --loader "\\EFI\\Linux\\arch-rescue.efi" \
    --unicode
```

Do not build the rescue UKI in `install.bash`.

Do not run `mkosi` in the target chroot.

## Existing rescue-root Reuse

There must remain one source rescue script:

```text
iso/airootfs/usr/local/bin/rescue-root
```

The rescue UKI build should copy that script into its image.

If the script eventually moves to a shared location, both the ISO and rescue UKI should install from that shared path.

V1 should not fork the script into two divergent copies.

## Validation Commands

After implementation, run:

```bash
bash -n install.bash iso/build.sh rescue-uki/build.sh iso/release.sh iso/airootfs/usr/local/bin/rescue-root iso/airootfs/usr/local/bin/install-arch
```

If available:

```bash
shellcheck install.bash iso/build.sh rescue-uki/build.sh iso/release.sh iso/airootfs/usr/local/bin/rescue-root iso/airootfs/usr/local/bin/install-arch
```

Build rescue UKI and USB ISO with the single supported build command:

```bash
sudo ./iso/build.sh
```

Verify rescue artifact after the top-level build:

```bash
file artifacts/arch-rescue.efi
ls -lh artifacts/arch-rescue.efi
```

Verify ISO contains rescue artifact:

```bash
# inspect built ISO contents with an appropriate ISO extraction/listing tool
```

## Test Plan

VM first.

1. Build rescue UKI.
2. Build USB ISO containing rescue UKI.
3. Install system from USB ISO in VM.
4. Confirm target ESP contains:

```text
/efi/EFI/Linux/arch-linux.efi
/efi/EFI/Linux/arch-rescue.efi
```

5. Confirm EFI boot entries include:

```text
arch-linux
arch-rescue
```

6. Confirm `sbctl verify` sees signed rescue UKI.
7. Boot normal system.
8. Reboot into `arch-rescue` firmware entry.
9. Confirm rescue root login works.
10. Confirm `rescue-root` exists.
11. Test manual repair mount.
12. Test chroot entry.
13. Test snapshot replacement in a controlled VM.
14. Confirm normal system boots afterward.

Physical machine testing only after VM success.

## Rollback Plan

If rescue UKI integration causes problems:

1. Remove the preflight requirement for `artifacts/arch-rescue.efi`.
2. Stop copying rescue UKI to ESP.
3. Stop creating `arch-rescue` boot entry.
4. Leave the standalone `rescue-uki/` build system in place for later testing.

This rollback must not affect the normal `arch-linux` install flow.

## Future V2 Notes

Do not implement now.

Future `rescue-reinstall.bash` will require refactoring installer logic into shared code.

Preserve set for V2 reinstall:

```text
@home
@sbctl
@iwd
@tailscale
@netbird
```

Everything else is deleted/recreated.

V2 must never enroll Secure Boot keys and must never require firmware Setup Mode.
