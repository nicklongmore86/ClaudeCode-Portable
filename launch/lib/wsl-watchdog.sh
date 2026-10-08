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
        # Only our acquired device is eligible; never detach a replacement.
        [[ $devices != *$'\n'* ]] || return 1
        [ -n "$loop" ] || loop=${devices%%:*} # Acquire's interrupted assignment only.
        [ "${devices%%:*}" = "$loop" ] || return 1
        if findmnt -rn -S "$loop" >/dev/null; then
            umount "$loop" || return 1
        fi
        losetup -d "$loop" || return 1
        devices=$(attached) || return 1
        [ -z "$devices" ] || return 1
    fi
    rmdir -- "$target" 2>/dev/null || printf 'Warning: empty WSL mountpoint remains: %s\n' "$target" >&2
}
recovery_log() {
    # Unique, exclusive creation: never follow a pre-planted logfile symlink.
    local message=$1
    printf '%s\n' "$message" >&2
    (umask 077; set -C
        printf '%s\n' "$message" "Image: $image" "Device: $loop" "Lock: $lock" \
            "Do NOT unplug. Stop all drive sessions. Inspect findmnt -S '$loop' and losetup -j '$image'." \
            "If still attached, sync; sudo umount '$loop'; sudo losetup -d '$loop'." \
            'Verify detach in all distros before repairing the image or manually recovering the lock.' \
            > "$image.recovery.$token.log")
}
release_lock() {
    if ! owns_lock; then
        recovery_log 'WSL image teardown completed, but lock token changed or is unreadable; lock left untouched.'
        return 1
    fi
    rm -f -- "$lock/owner" && rmdir -- "$lock"
}
case $mode in
    acquire)
        command -v setsid >/dev/null || exit 1
        owns_lock || exit 1
        # Privileged rollback covers signals during loop setup, including the
        # assignment window; the watcher receives the exact acquired device.
        trap 'exit 1' HUP INT TERM
        trap teardown EXIT
        loop=$(losetup --find --show "$image") || exit 1
        launcher_start=$(process_identity "$launcher") || exit 1
        [ -n "$launcher_start" ] || exit 1
        acquirer_start=$(process_identity "$$") || exit 1
        # Inherit ignored signals across fork/exec. Signals in this tiny window
        # are dropped, not deferred; the watcher still covers launcher death.
        trap '' HUP INT TERM
        setsid bash "$0" watch "$launcher" "$image" "$target" "$lock" "$token" "$loop" "$launcher_start" "$$" "$acquirer_start" </dev/null >/dev/null 2>&1 &
        trap 'exit 1' HUP INT TERM
        mount -t ext4 -o nosuid,nodev "$loop" "$target" || exit 1
        trap - EXIT
        printf '%s\n' "$loop"
        ;;
    watch)
        trap '' HUP INT TERM
        # Wait on process identity, not drive metadata. Once-per-second polling
        # avoids repeated lock-file reads over DrvFS during long CLI sessions.
        while [ "$(process_identity "$acquirer")" = "$acquirer_start" ]; do sleep 1; done
        while [ "$(process_identity "$launcher")" = "$launcher_start" ]; do sleep 1; done
        # A normal launcher exit has already detached and removed the lock.
        devices=$(attached) || devices=unknown
        if [ -z "$devices" ] && [ ! -e "$lock" ]; then exit 0; fi
        # Twelve attempts with 2,4,8,16,30... second delays: at most 240 seconds
        # of backoff. Never use lazy unmount: busy users must release the image.
        delay=2
        for ((attempt=1; attempt<=12; attempt++)); do
            if details=$(teardown 2>&1); then
                release_lock
                exit $?
            fi
            if [ "$attempt" -lt 12 ]; then
                sleep "$delay"
                delay=$((delay * 2))
                [ "$delay" -le 30 ] || delay=30
            fi
        done
        recovery_log "WSL watchdog teardown failed after 12 attempts; lock retained. $details"
        exit 1
        ;;
    *) exit 2;;
esac
