#!/bin/bash
# Invoked through sudo. A detached copy retains privilege after the tty closes.
set -u
mode=$1 launcher=$2 image=$3 target=$4 lock=$5 token=$6
loop=${7:-}
launcher_start=${8:-}
acquirer=${9:-}
acquirer_start=${10:-}
process_identity() { awk '$3 != "Z" {print $22}' "/proc/$1/stat" 2>/dev/null; }

identity=${11:-}
helper_dir=${BASH_SOURCE[0]%/*}
# shellcheck source=launch/lib/wsl-identity.sh
. "$helper_dir/wsl-identity.sh"
invoker_uid=${SUDO_UID:-$(id -u)}
invoker_gid=${SUDO_GID:-$(id -g)}

owns_lock() { [ "$(head -n 1 -- "$lock/owner" 2>/dev/null)" = "$token" ]; }
other_session() {
    local owner
    owner=$(head -n 1 -- "$lock/owner" 2>/dev/null) || return 1
    [ -n "$owner" ] && [ "$owner" != "$token" ]
}
attached() { losetup -j "$image"; }
teardown_pinned() {
    local current
    drive_wsl_identity_verify "$image" "$loop" "$identity" || {
        printf 'Attachment identity changed or cannot be verified; refusing teardown.\n' >&2
        return 1
    }
    if findmnt -rn -S "$loop" >/dev/null; then
        # Verify immediately before each destructive operation.
        drive_wsl_identity_verify "$image" "$loop" "$identity" || return 1
        umount "$loop" || return 1
    fi
    case $identity in
        mount:*)
            # Mount ID vanishes on unmount, but the pinned fd prevents a new
            # attachment from reusing this loop generation until we close it.
            current=$(drive_wsl_identity_base "$image" "$loop") || return 1
            [ "$current" = "${identity#*$'\n'}" ] || return 1;;
        *) drive_wsl_identity_verify "$image" "$loop" "$identity" || return 1;;
    esac
    losetup -d "$loop"
}
teardown() {
    sync || return 1
    local devices status
    devices=$(attached) || return 1
    if [ -z "$devices" ] && [ -n "$loop" ] && ! drive_wsl_identity_inactive "$loop"; then
        printf 'Image mapping disappeared but loop is active or unreadable; refusing teardown.\n' >&2
        return 1
    fi
    if [ -n "$devices" ]; then
        if [ -z "$loop" ] || [ -z "$identity" ]; then
            printf 'No recorded attachment identity; refusing teardown.\n' >&2; return 1
        fi
        drive_wsl_identity_pin "$loop" || return 1
        teardown_pinned
        status=$?
        drive_wsl_identity_close
        [ "$status" = 0 ] || return 1
        devices=$(attached) || return 1
        [ -z "$devices" ] || return 1
    fi
    rmdir -- "$target" 2>/dev/null || printf 'Warning: empty WSL mountpoint remains: %s\n' "$target" >&2
}
recovery_log() {
    local message=$1 advice=${2:-'Do NOT unplug. Stop all drive sessions and verify the attachment before manual recovery.'}
    printf '%s\n' "$message" >&2
    # No root write into a user-controlled path. Drop privilege before opening;
    # Python uses O_EXCL|O_NOFOLLOW|O_NONBLOCK and rejects existing special files.
    timeout --kill-after=1 5 setpriv --reuid="$invoker_uid" --regid="$invoker_gid" --clear-groups \
        python3 "$helper_dir/wsl-recovery-log.py" "$image.recovery.$token.log" \
        "$message
Image: $image
Device: $loop
Lock: $lock
$advice
Inspect findmnt -S '$loop' and losetup -j '$image'. Verify all distros before recovering the lock."
}
release_lock() {
    if ! owns_lock; then
        recovery_log 'WSL image is detached; lock token changed or is unreadable. Lock left for manual recovery.' 'The image is detached; only manual lock recovery remains.'
        return 1
    fi
    rm -f -- "$lock/owner" && rmdir -- "$lock"
}
case $mode in
    acquire)
        for dependency in setsid setpriv timeout python3; do
            command -v "$dependency" >/dev/null || { printf 'WSL sudo backend requires %s.\n' "$dependency" >&2; exit 1; }
        done
        owns_lock || exit 1
        # Privileged rollback covers signals during loop setup, including the
        # assignment window; the watcher receives the exact acquired device.
        trap 'exit 1' HUP INT TERM
        trap teardown EXIT
        loop=$(losetup --find --show "$image") || exit 1
        # Capture diskseq before mounting where available. Older kernels need
        # the unique live mount ID; capture that immediately after mount.
        identity=$(drive_wsl_identity_capture "$image" "$loop") || identity=
        mount -t ext4 -o nosuid,nodev "$loop" "$target" || exit 1
        [ -n "$identity" ] || identity=$(drive_wsl_identity_capture "$image" "$loop") || exit 1
        launcher_start=$(process_identity "$launcher") || exit 1
        [ -n "$launcher_start" ] || exit 1
        acquirer_start=$(process_identity "$$") || exit 1
        # Inherit ignored signals across fork/exec. Signals in this tiny window
        # are dropped, not deferred; the watcher still covers launcher death.
        trap '' HUP INT TERM
        setsid bash "$0" watch "$launcher" "$image" "$target" "$lock" "$token" "$loop" "$launcher_start" "$$" "$acquirer_start" "$identity" </dev/null >/dev/null 2>&1 &
        trap 'exit 1' HUP INT TERM
        trap - EXIT
        printf '%s\n%s\n' "$loop" "$identity"
        ;;
    watch)
        trap '' HUP INT TERM
        # Wait on process identity, not drive metadata. Once-per-second polling
        # avoids repeated lock-file reads over DrvFS during long CLI sessions.
        while [ "$(process_identity "$acquirer")" = "$acquirer_start" ]; do sleep 1; done
        while [ "$(process_identity "$launcher")" = "$launcher_start" ]; do sleep 1; done
        # A readable foreign token means our session ended and a successor
        # owns the image. Never touch its device, even if the loop name matches.
        other_session && exit 0
        # A normal launcher exit has already detached and removed the lock.
        devices=$(attached) || devices=unknown
        if [ -z "$devices" ] && [ ! -e "$lock" ] && drive_wsl_identity_inactive "$loop"; then exit 0; fi
        # Twelve attempts with 2,4,8,16,30... second delays: at most 240 seconds
        # of backoff. Never use lazy unmount: busy users must release the image.
        delay=2
        for ((attempt=1; attempt<=12; attempt++)); do
            other_session && exit 0
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
    cleanup) teardown;;
    *) exit 2;;
esac
