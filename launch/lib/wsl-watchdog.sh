#!/bin/bash
# Invoked through sudo. A detached copy retains privilege after the tty closes.
set -u
mode=$1 launcher=$2 image=$3 target=$4 lock=$5 token=$6
loop=${7:-}
launcher_start=${8:-}
acquirer=${9:-}
acquirer_start=${10:-}
process_identity() { awk '$3 != "Z" {print $22}' "/proc/$1/stat" 2>/dev/null; }

owns_lock() { [ "$(head -n 1 -- "$lock/owner" 2>/dev/null)" = "$token" ]; }
attached() { losetup -j "$image"; }
teardown() {
    sync || return 1
    local devices
    devices=$(attached) || return 1
    if [ -n "$devices" ]; then
        # Only the original device is ours. Refuse ambiguity or a replacement.
        [[ $devices != *$'\n'* ]] || return 1
        [ -n "$loop" ] || loop=${devices%%:*}
        [ "${devices%%:*}" = "$loop" ] || return 1
        if findmnt -rn -S "$loop" >/dev/null; then
            umount "$target" || return 1
        fi
        losetup -d "$loop" || return 1
        devices=$(attached) || return 1
        [ -z "$devices" ] || return 1
    fi
    rmdir -- "$target" 2>/dev/null || printf 'Warning: empty WSL mountpoint remains: %s\n' "$target" >&2
}
release_lock() {
    owns_lock || return 1
    rm -f -- "$lock/owner" && rmdir -- "$lock"
}
case $mode in
    acquire)
        command -v setsid >/dev/null || exit 1
        owns_lock || exit 1
        # On failure or signals before the detached watcher starts, this root
        # invocation owns rollback. The launcher still owns lock release.
        trap 'exit 1' HUP INT TERM
        trap '[ -z "$loop" ] || teardown' EXIT
        # Start before any kernel acquisition, including signals during losetup.
        # No terminal, inherited pipes or sudo ticket is needed by the watcher.
        launcher_start=$(process_identity "$launcher") || exit 1
        [ -n "$launcher_start" ] || exit 1
        acquirer_start=$(process_identity "$$") || exit 1
        # Inherit ignored signals across fork/exec, closing the small window
        # before setsid has detached and the watch branch installs its traps.
        trap '' HUP INT TERM
        setsid bash "$0" watch "$launcher" "$image" "$target" "$lock" "$token" "" "$launcher_start" "$$" "$acquirer_start" </dev/null >/dev/null 2>&1 &
        trap 'exit 1' HUP INT TERM
        loop=$(losetup --find --show "$image") || exit 1
        mount -t ext4 -o nosuid,nodev "$loop" "$target" || exit 1
        trap - EXIT
        printf '%s\n' "$loop"
        ;;
    watch)
        trap '' HUP INT TERM
        # Never race an in-flight privileged acquisition, even if the launcher
        # was killed before sudo finished attaching/mounting.
        while [ "$(process_identity "$acquirer")" = "$acquirer_start" ]; do sleep 0.2; done
        # Lock-token changes also stop a watcher after normal launcher cleanup.
        # No root process persists after release, even if the PID is reused.
        while [ "$(process_identity "$launcher")" = "$launcher_start" ] && owns_lock; do
            sleep 0.2
        done
        owns_lock || exit 0
        teardown && release_lock
        ;;
    *) exit 2;;
esac
