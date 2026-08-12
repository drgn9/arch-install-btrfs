#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT_DIR="$REPO_DIR/artifacts"
ARTIFACT="$ARTIFACT_DIR/arch-rescue.efi"
ROOTPW_FILE="$SCRIPT_DIR/mkosi.rootpw"
RESCUE_SOURCE="$REPO_DIR/iso/airootfs/usr/local/bin/rescue-root"
RESCUE_OVERLAY="$SCRIPT_DIR/mkosi.extra/usr/local/bin/rescue-root"
TRUSTED_PACCHECK_SOURCE="$REPO_DIR/iso/airootfs/usr/local/bin/trusted-paccheck"
TRUSTED_PACCHECK_OVERLAY="$SCRIPT_DIR/mkosi.extra/usr/local/bin/trusted-paccheck"
PAYLOAD_OVERLAY="$SCRIPT_DIR/mkosi.extra/usr/local/share/arch-new-install"

# The rescue image is built with a pinned mkosi version so builds do not
# silently change behavior when the build machine upgrades its mkosi package.
# Bump MKOSI_VERSION deliberately after reading the mkosi release notes.
MKOSI_VERSION=26
MKOSI_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/arch-new-install/mkosi/v$MKOSI_VERSION"

cleanup() {
    rm -f "$ROOTPW_FILE"
    rm -f "$RESCUE_OVERLAY"
    rm -f "$TRUSTED_PACCHECK_OVERLAY"
    rm -rf "$PAYLOAD_OVERLAY"
}
trap cleanup EXIT

if [[ ${EUID:-0} -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if [[ ! -f "$RESCUE_SOURCE" ]]; then
    echo "ERROR: Missing rescue script: $RESCUE_SOURCE" >&2
    exit 1
fi

if [[ ! -f "$TRUSTED_PACCHECK_SOURCE" ]]; then
    echo "ERROR: Missing trusted paccheck script: $TRUSTED_PACCHECK_SOURCE" >&2
    exit 1
fi

deps_needed=()
for dep in python3 rsync openssl git; do
    command -v "$dep" &>/dev/null || deps_needed+=("$dep")
done

if [[ ${#deps_needed[@]} -gt 0 ]]; then
    echo "Installing rescue UKI build dependencies: ${deps_needed[*]}"
    pacman -S --needed --noconfirm python rsync openssl git
fi

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

hashed_password=$(printf '%s' "$password" | openssl passwd -6 -stdin)
unset password password_confirm

printf 'hashed:%s\n' "$hashed_password" >"$ROOTPW_FILE"
chmod 0600 "$ROOTPW_FILE"
unset hashed_password

install -D -m 0755 "$RESCUE_SOURCE" "$RESCUE_OVERLAY"
install -D -m 0755 "$TRUSTED_PACCHECK_SOURCE" "$TRUSTED_PACCHECK_OVERLAY"

# Rescue reinstall payload: package lists, static settings, and shared
# installer code, frozen into the image at build time. The version file
# lets the reinstall action print how old its embedded payload is.
rm -rf "$PAYLOAD_OVERLAY"
install -d -m 0755 "$PAYLOAD_OVERLAY"
cp -r "$REPO_DIR/packages" "$PAYLOAD_OVERLAY/packages"
cp -r "$REPO_DIR/settings" "$PAYLOAD_OVERLAY/settings"
install -m 0644 "$REPO_DIR/installer-common.bash" "$PAYLOAD_OVERLAY/installer-common.bash"
payload_revision=$(git -C "$REPO_DIR" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)
printf 'built %s from revision %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$payload_revision" \
    >"$PAYLOAD_OVERLAY/payload-version"

rm -rf "$SCRIPT_DIR/mkosi.output"
rm -f "$ARTIFACT"

if [[ ! -d "$MKOSI_HOME" ]]; then
    echo "Downloading mkosi v$MKOSI_VERSION (one-time download; cached for future builds)..."
    git clone --depth 1 --branch "v$MKOSI_VERSION" https://github.com/systemd/mkosi "$MKOSI_HOME"
fi

echo "Building rescue UKI..."
PYTHONPATH="$MKOSI_HOME" python3 -m mkosi -C "$SCRIPT_DIR" build

shopt -s nullglob
uki_outputs=("$SCRIPT_DIR"/mkosi.output/*.efi)
shopt -u nullglob
if (( ${#uki_outputs[@]} != 1 )) || [[ ! -f "${uki_outputs[0]}" ]]; then
    echo "ERROR: Expected exactly one rescue UKI in $SCRIPT_DIR/mkosi.output" >&2
    exit 1
fi

install -D -m 0644 "${uki_outputs[0]}" "$ARTIFACT"

echo "Rescue UKI written to: $ARTIFACT"
ls -lh "$ARTIFACT"
