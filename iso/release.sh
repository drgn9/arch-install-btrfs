#!/usr/bin/env bash

# Publishes the newest ISO from iso/out/ to the targets configured in
# iso/release.conf (copy release.conf.example and fill in what you use).
# Build the ISO first: sudo ./iso/build.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
CONF="$SCRIPT_DIR/release.conf"

if [[ ! -f "$CONF" ]]; then
    echo "ERROR: $CONF not found." >&2
    echo "Copy $SCRIPT_DIR/release.conf.example to release.conf and fill in your targets." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONF"

iso_path=$(printf '%s\n' "$OUT_DIR"/arch-new-install-*.iso | sort | tail -n 1)
if [[ ! -f "$iso_path" ]]; then
    echo "ERROR: No ISO found in $OUT_DIR. Build one first: sudo ./iso/build.sh" >&2
    exit 1
fi
iso_name=$(basename "$iso_path")

# arch-new-install-2026.07.07-x86_64.iso -> 2026.07.07
version=${iso_name#arch-new-install-}
version=${version%-x86_64.iso}
tag="v$version"

echo "Releasing $iso_name as $tag"
(cd "$OUT_DIR" && sha256sum "$iso_name" >sha256sums.txt)

failed=()

# --- GitHub ---
if [[ -n "${GITHUB_REPO:-}" ]]; then
    echo "==> GitHub: creating release $tag on $GITHUB_REPO"
    if ! command -v gh &>/dev/null; then
        echo "ERROR: GITHUB_REPO is set but github-cli is not installed." >&2
        failed+=(github)
    elif ! gh release create "$tag" "$iso_path" "$OUT_DIR/sha256sums.txt" \
        --repo "$GITHUB_REPO" --title "$version" \
        --notes "Arch New Installer ISO $version. Verify with sha256sums.txt."; then
        failed+=(github)
    fi
else
    echo "==> GitHub: not configured, skipping"
fi

# --- Forgejo ---
if [[ -n "${FORGEJO_URL:-}" && -n "${FORGEJO_REPO:-}" && -n "${FORGEJO_TOKEN:-}" ]]; then
    echo "==> Forgejo: creating release $tag on $FORGEJO_URL/$FORGEJO_REPO"
    # Creates the tag on the default branch head if it does not exist yet,
    # so push the release commit to Forgejo before running this.
    response=$(curl -sS -X POST \
        -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" \
        -d "{\"tag_name\":\"$tag\",\"name\":\"$version\",\"body\":\"Arch New Installer ISO $version. Verify with sha256sums.txt.\"}" \
        "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/releases") || response=""
    release_id=$(grep -om1 '"id":[0-9]*' <<<"$response" | cut -d: -f2 || true)
    if [[ -z "$release_id" ]]; then
        echo "ERROR: Forgejo release creation failed: $response" >&2
        failed+=(forgejo)
    else
        for asset in "$iso_path" "$OUT_DIR/sha256sums.txt"; do
            if ! curl -sSf -X POST -H "Authorization: token $FORGEJO_TOKEN" \
                -F "attachment=@$asset" \
                "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/releases/$release_id/assets" >/dev/null; then
                echo "ERROR: Forgejo upload failed for $(basename "$asset")" >&2
                failed+=(forgejo)
                break
            fi
        done
    fi
else
    echo "==> Forgejo: not configured, skipping"
fi

# --- Cloudflare R2 ---
if [[ -n "${R2_REMOTE:-}" && -n "${R2_BUCKET:-}" ]]; then
    echo "==> R2: uploading to $R2_REMOTE:$R2_BUCKET"
    if ! command -v rclone &>/dev/null; then
        echo "ERROR: R2_REMOTE is set but rclone is not installed." >&2
        failed+=(r2)
    elif ! {
        rclone copyto --progress "$iso_path" "$R2_REMOTE:$R2_BUCKET/$iso_name" &&
        rclone copyto "$OUT_DIR/sha256sums.txt" "$R2_REMOTE:$R2_BUCKET/sha256sums.txt" &&
        # server-side copy to a stable name so the download URL never changes
        rclone copyto "$R2_REMOTE:$R2_BUCKET/$iso_name" "$R2_REMOTE:$R2_BUCKET/arch-new-install-latest.iso"
    }; then
        failed+=(r2)
    fi
else
    echo "==> R2: not configured, skipping"
fi

echo ""
if (( ${#failed[@]} > 0 )); then
    echo "Release finished with failures: ${failed[*]}" >&2
    exit 1
fi
echo "Release $tag complete."
