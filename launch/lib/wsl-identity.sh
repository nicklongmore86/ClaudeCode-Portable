#!/bin/bash
# Shared by the launcher and privileged watchdog. No mutable lock data is part
# of attachment identity. Callers must fail closed when capture/verification fails.
drive_wsl_identity_base() {
    local image=$1 device=$2 attached file_id node_id backing kernel_id
    case $device in /dev/loop[0-9]*) :;; *) return 1;; esac
    attached=$(losetup -j "$image") || return 1
    [[ $attached != *$'\n'* ]] && [ "${attached%%:*}" = "$device" ] || return 1
    file_id=$(stat -Lc '%d:%i' -- "$image") || return 1
    node_id=$(cat "/sys/block/${device##*/}/dev") || return 1
    kernel_id=$(losetup -ln -O BACK-INO,BACK-MAJ:MIN "$device") || return 1
    backing=$(cat "/sys/block/${device##*/}/loop/backing_file") || return 1
    [ -n "$kernel_id" ] && [ -n "$backing" ] || return 1
    printf '%s\n' "$file_id" "$node_id" "$kernel_id" "$backing"
}

drive_wsl_identity_capture() {
    local base sequence mounted
    base=$(drive_wsl_identity_base "$1" "$2") || return 1
    sequence=$(cat "/sys/block/${2##*/}/diskseq" 2>/dev/null) || sequence=
    case $sequence in
        ''|*[!0-9]*)
            # A live mount ID prevents reuse of the fallback identity. Teardown
            # must pin the device before verification and retain the fd through
            # detach; otherwise this fallback is not safe after unmount.
            mounted=$(findmnt -rn -S "$2" -o ID,MAJ:MIN,TARGET --raw) || return 1
            [ -n "$mounted" ] && [[ $mounted != *$'\n'* ]] || return 1
            printf 'mount:%s\n%s\n' "$mounted" "$base";;
        *) printf 'diskseq:%s\n%s\n' "$sequence" "$base";;
    esac
}

drive_wsl_identity_verify() {
    local current
    [ -n "$3" ] || return 1
    current=$(drive_wsl_identity_capture "$1" "$2") || return 1
    [ "$current" = "$3" ]
}

drive_wsl_identity_pin() {
    # An open loop fd prevents its number being recycled during fallback
    # unmount/detach. losetup -d completes only after this fd is closed.
    exec {drive_wsl_identity_fd}<"$1"
}

drive_wsl_identity_close() {
    if [ -n "${drive_wsl_identity_fd:-}" ]; then
        exec {drive_wsl_identity_fd}<&-
        drive_wsl_identity_fd=
    fi
}

# A pathname lookup alone is insufficient when the image was replaced/unlinked.
# Prove the device itself is inactive before treating a missing mapping as clean.
drive_wsl_identity_inactive() {
    local direct
    direct=$(losetup -ln -O BACK-INO,BACK-MAJ:MIN "$1") || return 1
    [ -z "${direct//[[:space:]]/}" ] || return 1
    ! findmnt -rn -S "$1" >/dev/null
}
