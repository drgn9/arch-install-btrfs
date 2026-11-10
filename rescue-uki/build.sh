#!/usr/bin/env bash

# Builds the rescue UKI with mkosi and writes it to artifacts/arch-rescue.efi.
# Run as root on an Arch Linux machine: sudo ./rescue-uki/build.sh

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT="$REPO_DIR/artifacts/arch-rescue.efi"
ROOTPW_FILE="$SCRIPT_DIR/mkosi.rootpw"
WORK_DIR=

cleanup() {
    rm -f "$ROOTPW_FILE"
    if [[ -n "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ${EUID:-0} -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

echo "Installing build dependencies..."
pacman -S --needed --noconfirm \
    mkosi python-pefile openssl git systemd-ukify kmod libarchive cpio zstd

read_secret() {
    local prompt=$1
    local secret

    if [[ -r /dev/tty ]]; then
        read -rsp "$prompt" secret </dev/tty
        printf '\n' >/dev/tty
    else
        read -rsp "$prompt" secret
        printf '\n'
    fi
    printf '%s' "$secret"
}

password=$(read_secret "Rescue root password: ")
password_confirm=$(read_secret "Confirm rescue root password: ")

if [[ -z "$password" ]]; then
    echo "ERROR: Rescue root password cannot be empty." >&2
    exit 1
fi

if [[ "$password" != "$password_confirm" ]]; then
    echo "ERROR: Rescue root passwords do not match." >&2
    exit 1
fi

# mkosi reads the root password from mkosi.rootpw next to its configuration.
printf 'hashed:%s\n' "$(printf '%s' "$password" | openssl passwd -6 -stdin)" >"$ROOTPW_FILE"
unset password password_confirm

# Keep unpacked images off /tmp's size-limited tmpfs. mkosi keeps its own
# package cache between builds; output and build roots are temporary.
WORK_DIR=$(mktemp -d /var/tmp/arch-new-install-rescue.XXXXXX)

# The version stamp lets the reinstall action print how old its embedded
# payload is. The payload itself is listed under ExtraTrees= in mkosi.conf.
install -d -m 0755 "$WORK_DIR/payload"
payload_revision=$(git -C "$REPO_DIR" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)
printf 'built %s from revision %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$payload_revision" \
    >"$WORK_DIR/payload/payload-version"
chmod 0644 "$WORK_DIR/payload/payload-version"

rm -f "$ARTIFACT"

echo "Building rescue UKI..."
mkosi -C "$SCRIPT_DIR" \
    --extra-tree="$WORK_DIR/payload:/usr/local/share/arch-new-install" \
    --workspace-directory="$WORK_DIR" \
    --output-directory="$WORK_DIR/output" \
    build

shopt -s nullglob
uki_outputs=("$WORK_DIR"/output/*.efi)
shopt -u nullglob
if (( ${#uki_outputs[@]} != 1 )) || [[ ! -f "${uki_outputs[0]}" ]]; then
    echo "ERROR: Expected exactly one rescue UKI in $WORK_DIR/output" >&2
    exit 1
fi

install -D -m 0644 "${uki_outputs[0]}" "$ARTIFACT"

echo "Rescue UKI written to: $ARTIFACT"
ls -lh "$ARTIFACT"
