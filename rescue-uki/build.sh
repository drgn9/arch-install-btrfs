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
PAYLOAD_OVERLAY="$SCRIPT_DIR/mkosi.extra/usr/local/share/arch-new-install"

# The rescue image is built with a pinned mkosi version so builds do not
# silently change behavior when the build machine upgrades its mkosi package.
# Bump MKOSI_VERSION deliberately after reading the mkosi release notes.
MKOSI_VERSION=27.1
MKOSI_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/arch-new-install/mkosi/v$MKOSI_VERSION"
WORK_DIR=

cleanup() {
    rm -f "$ROOTPW_FILE"
    rm -f "$RESCUE_OVERLAY"
    rm -rf "$PAYLOAD_OVERLAY"
    # The cache bind mount exists only in the child mount namespace, which
    # has exited before this cleanup runs. This never removes host packages.
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

if [[ ! -f "$RESCUE_SOURCE" ]]; then
    echo "ERROR: Missing rescue script: $RESCUE_SOURCE" >&2
    exit 1
fi

deps_needed=()
for dep in python3 rsync openssl git unshare mount; do
    command -v "$dep" &>/dev/null || deps_needed+=("$dep")
done

if [[ ${#deps_needed[@]} -gt 0 ]]; then
    echo "Installing rescue UKI build dependencies: ${deps_needed[*]}"
    pacman -S --needed --noconfirm python rsync openssl git util-linux
fi

# shellcheck source-path=SCRIPTDIR source=../build-common.bash
source "$REPO_DIR/build-common.bash"
init_build_package_cache
echo "Using shared pacman package cache: $PACKAGE_CACHE_DIR"

# Keep unpacked images off /tmp's size-limited tmpfs. Only package archives
# persist across builds; metadata, output, and build roots are temporary.
WORK_DIR=$(mktemp -d /var/tmp/arch-new-install-rescue.XXXXXX)
MKOSI_PACKAGE_CACHE="$WORK_DIR/pkgcache"
mkdir -p "$MKOSI_PACKAGE_CACHE/cache/pacman/pkg"

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
# Mount only the package archives into mkosi's cache layout. Using /var as
# PackageCacheDirectory would also share the host's repository databases.
# The private namespace contains the mount even if the build fails, and
# exec ensures it is gone before the parent removes the temporary tree.
# shellcheck disable=SC2016 # Arguments expand in the child shell.
PYTHONPATH="$MKOSI_HOME" unshare --mount --propagation private -- bash -Eeuo pipefail -c '
    mount --bind "$1" "$2/cache/pacman/pkg"
    exec python3 -m mkosi -C "$3" \
        --package-cache-dir="$2" \
        --workspace-directory="$4" \
        --output-directory="$4/output" \
        --cache-directory= \
        --incremental=no \
        --history=no \
        build
' bash "$PACKAGE_CACHE_DIR" "$MKOSI_PACKAGE_CACHE" "$SCRIPT_DIR" "$WORK_DIR"

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
