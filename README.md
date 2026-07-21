# Arch New Installer

Niri-only Arch Linux installer for UEFI systems. The installer keeps destructive install operations in Bash, exposes package choices as plain text files under `packages/`, and exposes static system configuration files under `settings/`.

`mise` is installed on the target system as a normal package because it is useful for development workflows, but it is not used as the installer framework.

## Scope

- Niri desktop only.
- Btrfs root filesystem with workload-aware sibling subvolumes.
- Unified Kernel Images booted directly through EFISTUB.
- Optional LUKS root encryption with passphrase-only, TPM2 + PIN, or FIDO2 + PIN unlock. The selected unlock method is the only enrolled LUKS method after installation; TPM2/FIDO2 installs remove the temporary install passphrase slot and leave backup enrollment to post-install `systemd-cryptenroll` use. TPM2 enrollment binds to no PCRs and relies on the PIN for local authorization.
- Optional Secure Boot setup through always-installed `sbctl`.
- AppArmor always installed and enabled.
- Optional kernel lockdown.
- Optional Docker package installation.
- Snapper root snapshots with `snap-pac` pre/post pacman snapshots after installation.
- `iwd + systemd-networkd` networking. Wi-Fi networks joined in the live environment are copied into the installed system, so the first boot reconnects without re-entering credentials.
- `yay` installed from `yay-bin` for AUR package management.
- Optional full-disk secure wipe before partitioning: dm-crypt zero overwrite, or fast `blkdiscard` on SSDs.
- Full-disk declarative GPT layout through `sfdisk`.
- Installation uses the live environment's current pacman mirror list. `reflector` is installed on the target system but is not used or configured by the installer.

## Removed From The Old Installer

- GNOME desktop selection and GDM setup.
- NetworkManager selection and packages.
- Snapshot partition support.
- Manual `fdisk` or `cfdisk` partitioning.
- User-level Niri config installation.
- Reflector mirror selection and reflector config generation.

`gnome-keyring` and `gnome-firmware` are intentionally still installed because they are useful outside a GNOME desktop session.

## Disk Layout

The selected disk is fully consumed:

| Partition | Size | Type | Filesystem | Mount |
| --- | --- | --- | --- | --- |
| 1 | 1 GiB | EFI System | FAT32 | `/efi` |
| 2 | Remainder | Linux filesystem | Btrfs or LUKS + Btrfs | `/` |

The installer always recreates the ESP filesystem with `mkfs.fat -F 32 -n EFI`.

The Btrfs filesystem uses sibling subvolumes:

| Subvolume | Mount |
| --- | --- |
| `@` | `/` |
| `@snapshots` | `/.snapshots` |
| `@home` | `/home` |
| `@root` | `/root` |
| `@var_log` | `/var/log` |
| `@var_cache` | `/var/cache` |
| `@var_tmp` | `/var/tmp` |
| `@docker` | `/var/lib/docker` |
| `@containerd` | `/var/lib/containerd` |
| `@containers` | `/var/lib/containers` |
| `@machines` | `/var/lib/machines` |
| `@flatpak` | `/var/lib/flatpak` |
| `@libvirt` | `/var/lib/libvirt` |
| `@sbctl` | `/var/lib/sbctl` |
| `@iwd` | `/var/lib/iwd` |
| `@tailscale` | `/var/lib/tailscale` |
| `@netbird` | `/var/lib/netbird` |
| `@srv` | `/srv` |

Only `@` is managed by Snapper. `/var/lib/pacman` remains inside `@`, so package database changes are part of root rollback.

## Package Customization

Packages are declared in editable plain-text files before the installer runs. One package goes on each line. Blank lines and lines starting with `#` are ignored.

| File | Purpose |
| --- | --- |
| `packages/base.conf` | Base CLI, backup, security, network, AppArmor, sbctl, mise, reflector, and utility packages |
| `packages/desktop-base.conf` | Desktop common packages, fonts, audio, browser, firmware tools |
| `packages/desktop-niri.conf` | Niri compositor and Niri-session packages |
| `packages/base-docker.conf` | Optional Docker packages |
| `packages/desktop-driver-intel.conf` | Intel GPU packages, installed when Intel graphics are detected |
| `packages/desktop-driver-amd.conf` | AMD GPU packages, installed when AMD graphics are detected |

To add or remove packages, edit these files directly. All selected package names are validated against the sync databases before the target disk is touched, and installed into the target in a single pacman transaction.

## Settings Customization

Static root-owned system files are stored under `settings/` by subsystem:

```text
settings/
├── access/       # sudo and polkit policy
├── boot/         # kernel command line, mkinitcpio, and UKI presets
├── hardware/     # Bluetooth, Thunderbolt, and Wi-Fi configuration
├── network/      # networkd, resolved, iwd, and network sysctls
├── power/        # sleep, watchdog, and zram policy
├── rollback/     # Snapper rollback tooling
└── security/     # AppArmor, coredumps, kernel sysctls, and module policy
```

Each subsystem is a partial root filesystem. Everything after `settings/<subsystem>/` is the installed path without its leading slash. For example, `settings/rollback/usr/local/sbin/arch-rollback` installs to `/usr/local/sbin/arch-rollback`. The installer selects which files apply and preserves special handling where needed: `settings/security/etc/apparmor/parser.conf` is appended idempotently to the package-owned `/etc/apparmor/parser.conf` instead of replacing it.

Boot configuration is centralized under `settings/boot/`:

```text
settings/boot/
└── etc/
    ├── cmdline.d/
    │   ├── defaults.conf     # general boot behavior
    │   ├── security.conf     # hardening, LSM, audit, and initramfs policy
    │   ├── iommu.conf        # common DMA protection
    │   ├── intel.conf        # Intel-specific IOMMU enablement
    │   ├── lockdown.conf     # optional kernel lockdown
    │   └── filesystem.conf   # Btrfs root mount arguments
    ├── mkinitcpio.conf.plain
    ├── mkinitcpio.conf.encrypted
    └── mkinitcpio.d/
        ├── linux.preset
        └── linux-lts.preset
```

The common and filesystem command-line fragments are always installed. `intel.conf` is selected from CPU detection, `lockdown.conf` is selected by its prompt, and `/etc/cmdline.d/root.conf` contains only the root device selected at installation. The mkinitcpio files are the one path-mirroring exception because they are mutually exclusive variants: the encryption prompt selects one and installs it as `/etc/mkinitcpio.conf`. Dynamic files such as `/etc/hostname`, `/etc/hosts`, `/etc/fstab`, and `/etc/crypttab.initramfs` are also generated by `install.bash` from install-time choices.

## Rollback Snapshots

The installer creates a Snapper `root` config for `/`, mounts the sibling `@snapshots` subvolume at `/.snapshots`, disables timeline snapshots, enables count-based cleanup, and installs `snap-pac` after installer package work is finished.

Normal rollback is intentionally simple:

```bash
sudo arch-rollback
```

`arch-rollback` lists recent snap-pac pre/post pairs, shows `snapper status PRE..POST`, asks for confirmation, runs `snapper -c root undochange PRE..POST`, rebuilds UKIs with `mkinitcpio -P`, and signs/verifies UKIs when `sbctl` keys exist. It does not create safety snapshots or maintain rollback journals.

Expert direct form:

```bash
sudo arch-rollback PRE POST
```

For a broken system, boot the custom ISO and run `rescue-arch`. Its nuclear option replaces `@` from a selected Snapper snapshot, keeps the previous root as `@old-<timestamp>`, rebuilds/signs/verifies UKIs, and exits. Delete `@old-*` manually after confirming the restored system boots.

`restic` remains installed as a normal package for manual or future off-disk backup, but the installer no longer creates a local restic rollback repository or pacman hook.

## Install Flow

1. The live installer prompts for install choices.
2. The selected disk is optionally securely wiped.
3. `sfdisk` creates the fixed GPT layout.
4. The installer formats and mounts the target filesystems.
5. `pacstrap` installs the bootstrap system: `base`, `base-devel`, kernels, firmware, and CPU microcode.
6. Package files are read from the live checkout and installed into the mounted target with `pacman`.
7. The live installer writes target files under `/mnt` and uses `arch-chroot /mnt ...` for commands that must run inside the installed system.
8. Snapper is configured and `snap-pac` is installed after installer-driven package work is complete.
9. No installer project copy is left behind on the installed system.

## Quick Start

From the Arch live environment:

```bash
pacman -Sy --noconfirm git
git clone <repo-url>
bash arch-new-install/install.bash
```

The installer checks for internet access before touching anything and opens the `impala` Wi-Fi TUI if the system is offline.

Review every prompt carefully. The selected target disk is destroyed.

## Custom Live ISO

`iso/build.sh` builds a custom Arch live ISO with this installer baked in. The live environment boots with the repo at `/root/arch-new-install`, `gum`, `impala`, `git`, `btrfs-progs`, `snapper`, and `rsync` preinstalled, and a login message pointing at two launcher commands:

- `install-arch` — runs the installer. No network is needed until package download starts, and the installer's `impala` Wi-Fi flow covers wireless setup.
- `rescue-arch` — guided repair/rollback entry point for an existing installation. It can mount the root subvolume and ESP at `/mnt` for manual repair, or replace `@` from a selected Snapper snapshot and rebuild/sign/verify UKIs. Run `mount -a` inside the chroot if you need the remaining fstab entries mounted.

Build (as root, on an Arch Linux machine):

```bash
sudo ./iso/build.sh
```

The profile is assembled at build time from the `releng` profile shipped by the `archiso` package (installed automatically on first run), plus:

- `iso/packages.x86_64` — extra live-environment packages appended to the stock list
- `iso/airootfs/` — file overlay: the `install-arch` and `rescue-arch` launchers, plus `/etc/motd`
- the current working tree of this repo, copied to `/root/arch-new-install`

The ISO lands in `iso/out/` (gitignored). Write it to a USB stick with `dd`, or drop it on a Ventoy stick.

Update workflow: change the installer, re-run `sudo ./iso/build.sh`, re-copy the ISO. The ISO's age does not affect the installed system — pacstrap always pulls current packages from live mirrors — so rebuild when the installer changes, and every couple of months so the live environment's pacman keyring stays fresh.

### Publishing releases

`iso/release.sh` uploads the newest ISO from `iso/out/` plus a generated `sha256sums.txt` to any of three targets: a GitHub release (via `gh`), a Forgejo release (via the Forgejo API), and a Cloudflare R2 bucket (via `rclone`, including a stable `arch-new-install-latest.iso` copy).

Copy `iso/release.conf.example` to `iso/release.conf` (gitignored; keep it `chmod 600` — it holds the Forgejo token) and uncomment the targets you use. Commented-out targets are skipped. The release tag is derived from the ISO's build date, e.g. `v2026.07.07`.

Push the release commit to GitHub/Forgejo before running the script — both create the tag on the server-side default branch head.
