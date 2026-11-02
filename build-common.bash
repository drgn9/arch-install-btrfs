#!/usr/bin/env bash

# Shared setup for the ISO and rescue image builders. Source this file.

init_build_package_cache() {
    local configured_dirs
    configured_dirs=$(pacman-conf CacheDir)
    # pacman writes to the first usable cache. Use its first configured path
    # explicitly in both builders so they share downloads on custom hosts too.
    PACKAGE_CACHE_DIR=${configured_dirs%%$'\n'*}
    if [[ "$PACKAGE_CACHE_DIR" != /* ]]; then
        echo "ERROR: pacman-conf did not return an absolute CacheDir." >&2
        return 1
    fi

    # The rescue builder uses umask 077 for credentials. New shared cache
    # directories must still be searchable by pacman's download user.
    (umask 022; mkdir -p -- "$PACKAGE_CACHE_DIR")
    PACKAGE_CACHE_DIR=$(realpath -- "$PACKAGE_CACHE_DIR")
    if [[ ! -w "$PACKAGE_CACHE_DIR" ]]; then
        echo "ERROR: Package cache is not writable: $PACKAGE_CACHE_DIR" >&2
        return 1
    fi
}

write_build_pacman_conf() {
    local source_conf=$1 output_conf=$2 line
    # Expand includes before replacing CacheDir, preserving the profile's
    # repositories and all other settings in this build-only configuration.
    pacman-conf --config "$source_conf" | while IFS= read -r line; do
        [[ "$line" == CacheDir\ =* ]] && continue
        printf '%s\n' "$line"
        if [[ "$line" == '[options]' ]]; then
            printf 'CacheDir = %s\n' "$PACKAGE_CACHE_DIR"
        fi
    done >"$output_conf"
}
