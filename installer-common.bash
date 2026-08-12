# installer-common.bash - shared constants and helpers for the USB installer
# and the rescue reinstall path. Sourced, never executed.
# shellcheck shell=bash
# shellcheck disable=SC2034

BTRFS_MOUNT_OPTIONS="noatime,compress=zstd:3"
BTRFS_DATA_MOUNT_OPTIONS="$BTRFS_MOUNT_OPTIONS,nodev,nosuid"
BTRFS_STRICT_MOUNT_OPTIONS="$BTRFS_DATA_MOUNT_OPTIONS,noexec"
EFI_MOUNT_OPTIONS="fmask=0137,dmask=0027,nodev,nosuid,noexec"
BTRFS_SUBVOLUMES=(
    @
    @snapshots
    @home
    @root
    @var_log
    @var_cache
    @var_tmp
    @docker
    @containerd
    @containers
    @machines
    @portables
    @flatpak
    @libvirt
    @sbctl
    @iwd
    @tailscale
    @netbird
    @srv
)
BTRFS_SUBVOLUME_MOUNTS=(
    "@snapshots:/.snapshots"
    "@home:/home"
    "@root:/root"
    "@var_log:/var/log"
    "@var_cache:/var/cache"
    "@var_tmp:/var/tmp"
    "@docker:/var/lib/docker"
    "@containerd:/var/lib/containerd"
    "@containers:/var/lib/containers"
    "@machines:/var/lib/machines"
    "@portables:/var/lib/portables"
    "@flatpak:/var/lib/flatpak"
    "@libvirt:/var/lib/libvirt"
    "@sbctl:/var/lib/sbctl"
    "@iwd:/var/lib/iwd"
    "@tailscale:/var/lib/tailscale"
    "@netbird:/var/lib/netbird"
    "@srv:/srv"
)
# Rescue reinstall: these always survive; they are what make reinstall
# possible without Secure Boot Setup Mode or re-enrollment. @home is in
# neither fixed set because preserving it is a runtime choice.
BTRFS_PRESERVE_SUBVOLUMES=(
    @sbctl
    @iwd
    @tailscale
    @netbird
)
# Rescue reinstall: these are replaced. @ is renamed aside and retained
# until the reinstall succeeds; the others are deleted and recreated.
BTRFS_RECREATE_SUBVOLUMES=(
    @
    @snapshots
    @root
    @var_log
    @var_cache
    @var_tmp
    @docker
    @containerd
    @containers
    @machines
    @portables
    @flatpak
    @libvirt
    @srv
)
