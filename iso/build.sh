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
# honors .gitignore so local release credentials are not embedded.
mkdir -p "$PROFILE_DIR/airootfs/root/arch-new-install"
rsync -a --delete --filter=':- .gitignore' --exclude '.git' \
    "$REPO_DIR/" "$PROFILE_DIR/airootfs/root/arch-new-install/"

# Launcher commands and login message
install -D -m 0755 "$SCRIPT_DIR/airootfs/usr/local/bin/install-arch" \
    "$PROFILE_DIR/airootfs/usr/local/bin/install-arch"
install -D -m 0755 "$SCRIPT_DIR/airootfs/usr/local/bin/rescue-arch" \
    "$PROFILE_DIR/airootfs/usr/local/bin/rescue-arch"
install -D -m 0644 "$SCRIPT_DIR/airootfs/etc/motd" \
    "$PROFILE_DIR/airootfs/etc/motd"

# mkarchiso does not preserve file modes from the profile overlay; executable
# bits must be declared in profiledef.sh's file_permissions map.
sed -i '/^file_permissions=(/a\  ["/usr/local/bin/install-arch"]="0:0:755"\n  ["/usr/local/bin/rescue-arch"]="0:0:755"' \
    "$PROFILE_DIR/profiledef.sh"

sed -i 's/^iso_name=.*/iso_name="arch-new-install"/' "$PROFILE_DIR/profiledef.sh"

echo "Building ISO (this takes a few minutes and downloads packages)..."
mkarchiso -v -w "$WORK_DIR/build" -o "$OUT_DIR" "$PROFILE_DIR"

echo ""
echo "Done. ISO written to:"
printf '%s\n' "$OUT_DIR"/arch-new-install-*.iso | sort | tail -n 1
