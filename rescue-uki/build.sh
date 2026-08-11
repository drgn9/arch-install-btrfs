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

# The rescue image is built with a pinned mkosi version so builds do not
# silently change behavior when the build machine upgrades its mkosi package.
# Bump MKOSI_VERSION deliberately after reading the mkosi release notes.
MKOSI_VERSION=26
MKOSI_COMMIT=84af20892b61c8e177e391f997ded8b4cb5514f2
MKOSI_ORIGIN=https://github.com/systemd/mkosi
MKOSI_HOME="/var/cache/arch-new-install/mkosi/v$MKOSI_VERSION"
MKOSI_PARENT="${MKOSI_HOME%/*}"

cleanup() {
    rm -f "$ROOTPW_FILE"
    rm -f "$RESCUE_OVERLAY"
    rm -f "$TRUSTED_PACCHECK_OVERLAY"
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

rm -rf "$SCRIPT_DIR/mkosi.output"
rm -f "$ARTIFACT"

if [[ -e "$MKOSI_PARENT" || -L "$MKOSI_PARENT" ]]; then
    if [[ ! -d "$MKOSI_PARENT" || -L "$MKOSI_PARENT" ]]; then
        echo "ERROR: mkosi cache parent is not a real directory: $MKOSI_PARENT" >&2
        exit 1
    fi
    if [[ $(stat -c %u -- "$MKOSI_PARENT") -ne 0 ]]; then
        echo "ERROR: mkosi cache parent is not owned by root: $MKOSI_PARENT" >&2
        exit 1
    fi
    parent_mode=$(stat -c %a -- "$MKOSI_PARENT")
    if (( (8#$parent_mode & 0022) != 0 )); then
        echo "ERROR: mkosi cache parent is writable by group or others: $MKOSI_PARENT" >&2
        exit 1
    fi
else
    install -d -m 0700 -- "$MKOSI_PARENT"
fi

if [[ ! -e "$MKOSI_HOME" && ! -L "$MKOSI_HOME" ]]; then
    echo "Downloading mkosi v$MKOSI_VERSION (one-time download; cached for future builds)..."
    if ! git clone --depth 1 --single-branch --branch "v$MKOSI_VERSION" -- \
        "$MKOSI_ORIGIN" "$MKOSI_HOME"; then
        echo "ERROR: Failed to clone mkosi v$MKOSI_VERSION into $MKOSI_HOME" >&2
        exit 1
    fi
fi

cache_error() {
    echo "ERROR: Refusing mkosi cache $MKOSI_HOME: $1" >&2
    echo "Move the cache aside manually and rerun; it was not deleted or replaced." >&2
    exit 1
}

if [[ ! -d "$MKOSI_HOME" || -L "$MKOSI_HOME" || ! -d "$MKOSI_HOME/.git" ]]; then
    cache_error "it is not a standalone Git worktree"
fi

if ! non_root_path=$(find "$MKOSI_HOME" ! -user root -print -quit); then
    cache_error "ownership validation failed"
fi
if [[ -n "$non_root_path" ]]; then
    cache_error "all cached files and directories must be owned by root (found $non_root_path)"
fi

git_cache() {
    GIT_NO_REPLACE_OBJECTS=1 git \
        -c core.fsmonitor=false \
        -c core.hooksPath=/dev/null \
        -C "$MKOSI_HOME" "$@"
}

if ! worktree_root=$(git_cache rev-parse --show-toplevel 2>/dev/null); then
    cache_error "Git could not validate the worktree"
fi
physical_cache=$(cd -P -- "$MKOSI_HOME" && pwd)
if [[ "$worktree_root" != "$physical_cache" ]]; then
    cache_error "the Git worktree root is $worktree_root"
fi

if ! cache_head=$(git_cache rev-parse --verify 'HEAD^{commit}' 2>/dev/null); then
    cache_error "Git could not resolve HEAD"
fi
if [[ "$cache_head" != "$MKOSI_COMMIT" ]]; then
    cache_error "HEAD is $cache_head, expected $MKOSI_COMMIT"
fi

if ! cache_origin=$(git_cache config --local --no-includes --get-all remote.origin.url); then
    cache_error "Git origin is missing"
fi
if [[ "$cache_origin" != "$MKOSI_ORIGIN" ]]; then
    cache_error "Git origin is '$cache_origin', expected '$MKOSI_ORIGIN'"
fi

if ! cache_status=$(git_cache status --porcelain=v1 --untracked-files=all); then
    cache_error "Git status failed"
fi
if [[ -n "$cache_status" ]]; then
    cache_error "the Git worktree is not clean"
fi

if ! ignored_paths=$(git_cache ls-files --others --ignored --exclude-standard); then
    cache_error "ignored-file validation failed"
fi
if [[ -n "$ignored_paths" ]]; then
    cache_error "the Git worktree contains ignored files"
fi

if ! cache_flags=$(git_cache ls-files -v); then
    cache_error "Git index flag validation failed"
fi
if grep -qE '^[a-zS]' <<<"$cache_flags"; then
    cache_error "Git index contains assume-unchanged or skip-worktree entries"
fi

echo "Building rescue UKI..."
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$MKOSI_HOME" python3 -m mkosi -C "$SCRIPT_DIR" build

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
