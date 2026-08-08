#!/usr/bin/env bash

# Builds a custom Arch live ISO with this installer baked in.
# Run as root on an Arch Linux machine: sudo ./iso/build.sh
#
# The profile is assembled at build time from the archiso releng profile
# installed on this machine, so the profile format always matches the
# installed mkarchiso version. The ISO lands in iso/out/.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$SCRIPT_DIR/out"
RELENG_DIR=/usr/share/archiso/configs/releng
RESCUE_UKI_ARTIFACT="$REPO_DIR/artifacts/arch-rescue.efi"
RESCUE_UKI_DIR="$REPO_DIR/rescue-uki"

if [[ ${EUID:-0} -ne 0 ]]; then
    echo "ERROR: This script must be run as root (mkarchiso requires it)." >&2
    exit 1
fi

if ! command -v mkarchiso &>/dev/null || ! command -v rsync &>/dev/null; then
    echo "Installing build dependencies: archiso rsync"
    pacman -S --needed --noconfirm archiso rsync
fi

if [[ ! -d "$RELENG_DIR" ]]; then
    echo "ERROR: $RELENG_DIR not found. Is the archiso package installed correctly?" >&2
    exit 1
fi

clean_intermediate_outputs() {
    rm -rf \
        "$REPO_DIR/artifacts" \
        "$RESCUE_UKI_DIR/mkosi.output" \
        "$RESCUE_UKI_DIR/mkosi.cache" \
        "$RESCUE_UKI_DIR/mkosi.builddir" \
        "$RESCUE_UKI_DIR/mkosi.workspace" \
        "$RESCUE_UKI_DIR/.mkosi-private" \
        "$RESCUE_UKI_DIR/mkosi.credentials"

    rm -f \
        "$RESCUE_UKI_DIR/mkosi.rootpw" \
        "$RESCUE_UKI_DIR/mkosi.passphrase" \
        "$RESCUE_UKI_DIR/mkosi.extra/usr/local/bin/rescue-root" \
        "$RESCUE_UKI_DIR/mkosi.extra/usr/local/bin/trusted-paccheck"

    shopt -s nullglob
    rm -f \
        "$RESCUE_UKI_DIR"/*.efi \
        "$RESCUE_UKI_DIR"/*.efi.* \
        "$RESCUE_UKI_DIR"/*.raw \
        "$RESCUE_UKI_DIR"/*.raw.* \
        "$RESCUE_UKI_DIR"/*.tar \
        "$RESCUE_UKI_DIR"/*.tar.* \
        "$RESCUE_UKI_DIR"/*.manifest \
        "$RESCUE_UKI_DIR"/*.changelog \
        "$RESCUE_UKI_DIR"/*.sha256 \
        "$RESCUE_UKI_DIR"/*.bmap
    shopt -u nullglob
}

clean_previous_iso_outputs() {
    rm -rf "$OUT_DIR"
    install -d -m 0755 "$OUT_DIR"
}

echo "Building rescue UKI artifact..."
"$REPO_DIR/rescue-uki/build.sh"
if [[ ! -f "$RESCUE_UKI_ARTIFACT" ]]; then
    echo "ERROR: Rescue UKI artifact was not created: $RESCUE_UKI_ARTIFACT" >&2
    exit 1
fi

# /var/tmp instead of /tmp: the build needs several GB and /tmp is a
# size-limited tmpfs on most systems.
WORK_DIR=$(mktemp -d /var/tmp/arch-new-install-iso.XXXXXX)
cleanup() {
    umount -R "$WORK_DIR" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

PROFILE_DIR="$WORK_DIR/profile"
cp -r "$RELENG_DIR" "$PROFILE_DIR"

# Extra live-environment packages on top of the stock releng list
cat "$SCRIPT_DIR/packages.x86_64" >>"$PROFILE_DIR/packages.x86_64"

# Bake the current working tree of this repo into the live image. The filter
# honors .gitignore so generated build outputs are not embedded.
mkdir -p "$PROFILE_DIR/airootfs/root/arch-new-install"
rsync -a --delete --filter=':- .gitignore' --exclude '.git' \
    "$REPO_DIR/" "$PROFILE_DIR/airootfs/root/arch-new-install/"

# artifacts/ is gitignored, so copy the generated rescue UKI explicitly.
install -D -m 0644 "$RESCUE_UKI_ARTIFACT" \
    "$PROFILE_DIR/airootfs/root/arch-new-install/artifacts/arch-rescue.efi"

# Launcher commands and login message
install -D -m 0755 "$SCRIPT_DIR/airootfs/usr/local/bin/install-arch" \
    "$PROFILE_DIR/airootfs/usr/local/bin/install-arch"
install -D -m 0755 "$SCRIPT_DIR/airootfs/usr/local/bin/rescue-root" \
    "$PROFILE_DIR/airootfs/usr/local/bin/rescue-root"
install -D -m 0755 "$SCRIPT_DIR/airootfs/usr/local/bin/trusted-paccheck" \
    "$PROFILE_DIR/airootfs/usr/local/bin/trusted-paccheck"
install -D -m 0644 "$SCRIPT_DIR/airootfs/etc/motd" \
    "$PROFILE_DIR/airootfs/etc/motd"

# mkarchiso does not preserve file modes from the profile overlay; executable
# bits must be declared in profiledef.sh's file_permissions map.
sed -i '/^file_permissions=(/a\  ["/usr/local/bin/install-arch"]="0:0:755"\n  ["/usr/local/bin/rescue-root"]="0:0:755"\n  ["/usr/local/bin/trusted-paccheck"]="0:0:755"' \
    "$PROFILE_DIR/profiledef.sh"

sed -i 's/^iso_name=.*/iso_name="arch-btrfs"/' "$PROFILE_DIR/profiledef.sh"

echo "Building ISO (this takes a few minutes and downloads packages)..."
clean_previous_iso_outputs
mkarchiso -v -w "$WORK_DIR/build" -o "$OUT_DIR" "$PROFILE_DIR"

shopt -s nullglob
iso_outputs=("$OUT_DIR"/arch-btrfs-*.iso)
shopt -u nullglob
if (( ${#iso_outputs[@]} == 0 )); then
    echo "ERROR: ISO build finished but no arch-btrfs ISO was found in $OUT_DIR" >&2
    exit 1
fi
final_iso=$(printf '%s\n' "${iso_outputs[@]}" | sort | tail -n 1)

clean_intermediate_outputs

# The build runs as root; give the ISO and its directory back to the
# invoking user so it can be moved, deleted, or flashed without sudo.
if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_UID:$SUDO_GID" "$OUT_DIR" "$final_iso"
fi

echo ""
echo "Done. ISO written to:"
printf '%s\n' "$final_iso"
