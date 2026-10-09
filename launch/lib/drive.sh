#!/bin/sh
# shellcheck disable=SC3013
# -nt is supported by the system shells on both supported Unix platforms.
# Shared POSIX helpers. Call drive_environment only inside a child/subshell.
drive_fail() { printf '%s\n' "$*" >&2; return 1; }

drive_is_wsl() {
    if [ -n "${PORTABLE_AI_WSL:-}" ]; then
        case $PORTABLE_AI_WSL in
            1|true|yes) return 0;;
            *) return 1;;
        esac
    fi
    [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSL_INTEROP:-}" ] || grep -qi microsoft /proc/version 2>/dev/null
}

drive_resolve_wsl_cli() {
    # Consume PATH without word splitting or pathname expansion.
    drive_target_cli=$1
    drive_resolved_cli='' drive_resolved_cli_dir=''
    drive_cli_home=${drive_host_home:-$HOME}
    drive_remaining_path=$PATH:$drive_cli_home/.local/bin:$drive_cli_home/.npm-global/bin:$drive_cli_home/.claude/local:$drive_cli_home/.bun/bin:
    # Resolve nvm's default alias without sourcing shell startup files or nvm.
    # Version aliases (v22, 22, node, stable and lts/*) select the newest match.
    drive_nvm_alias=$(cat "$drive_cli_home/.nvm/alias/default" 2>/dev/null) || drive_nvm_alias=
    drive_nvm_depth=0
    while [ -n "$drive_nvm_alias" ] && [ "$drive_nvm_depth" -lt 8 ]; do
        case $drive_nvm_alias in *..*|/*) drive_nvm_alias=; break;; esac
        [ -f "$drive_cli_home/.nvm/alias/$drive_nvm_alias" ] || break
        drive_nvm_alias=$(cat "$drive_cli_home/.nvm/alias/$drive_nvm_alias") || break
        drive_nvm_depth=$((drive_nvm_depth + 1))
    done
    drive_nvm_versions=$(printf '%s\n' "$drive_cli_home"/.nvm/versions/node/*/bin | sort -Vr)
    drive_nvm_default=
    while IFS= read -r drive_nvm_bin; do
        [ -d "$drive_nvm_bin" ] || continue
        drive_nvm_version=${drive_nvm_bin%/bin}
        drive_nvm_version=${drive_nvm_version##*/}
        case $drive_nvm_alias in
            node|stable) drive_nvm_default=$drive_nvm_bin; break;;
            '') :;;
            *) case $drive_nvm_version in
                "$drive_nvm_alias"|"$drive_nvm_alias".*|v"$drive_nvm_alias"|v"$drive_nvm_alias".*)
                    drive_nvm_default=$drive_nvm_bin; break;;
            esac;;
        esac
    done <<EOF_NVM
$drive_nvm_versions
EOF_NVM
    if [ "$drive_nvm_alias" = system ]; then
        drive_remaining_path=/usr/local/bin:/usr/bin:$drive_remaining_path
    fi
    drive_remaining_path=$drive_remaining_path${NVM_BIN:-}:$drive_nvm_default:
    while IFS= read -r drive_nvm_bin; do
        [ ! -d "$drive_nvm_bin" ] || drive_remaining_path=$drive_remaining_path$drive_nvm_bin:
    done <<EOF_NVM
$drive_nvm_versions
EOF_NVM
    drive_remaining_path=$drive_remaining_path/usr/local/bin:/usr/bin:
    while [ -n "$drive_remaining_path" ]; do
        drive_dir_entry=${drive_remaining_path%%:*}
        drive_remaining_path=${drive_remaining_path#*:}
        [ -n "$drive_dir_entry" ] || continue
        drive_check_path=$(realpath -- "$drive_dir_entry/$drive_target_cli" 2>/dev/null) || continue
        if [ ! -f "$drive_check_path" ] || [ ! -x "$drive_check_path" ]; then continue; fi
        case "$drive_check_path" in *.exe|*.cmd|*.bat|/mnt/*) continue;; esac
        case $(stat -f -c %T -- "$drive_check_path") in v9fs|9p|virtiofs|drvfs) continue;; esac
        [ "$(head -c 2 -- "$drive_check_path")" != MZ ] || continue
        drive_resolved_cli=$drive_check_path
        # Keep the search directory, not the symlink target's node_modules dir.
        drive_resolved_cli_dir=$(CDPATH='' cd -- "$drive_dir_entry" && pwd -P) || return 1
        printf '%s\n' "$drive_resolved_cli"
        return 0
    done
    return 1
}

drive_decode_mount() {
    case $1 in *'
'*) drive_fail 'Multiple native volumes found; detach duplicate labels.'; return 1;; esac
    drive_discovered=$(printf '%b' "$1")
}

drive_wsl_lock() {
    DRIVE_WSL_LOCK="$drive_wsl_shared/state/wsl-state.lock"
    DRIVE_WSL_TOKEN=$(cat /proc/sys/kernel/random/uuid) || return 1
    # This short acquisition transaction defers exits until ownership is saved.
    # The pending signal is replayed after installing the normal traps.
    trap 'drive_lock_signal=INT' INT
    trap 'drive_lock_signal=TERM' TERM
    trap 'drive_lock_signal=HUP' HUP
    drive_lock_signal=
    if mkdir "$DRIVE_WSL_LOCK" 2>/dev/null; then
        DRIVE_WSL_LOCK_HELD=1
        printf '%s\nhost=%s distro=%s pid=%s\n' "$DRIVE_WSL_TOKEN" "$(hostname)" "${WSL_DISTRO_NAME:-unknown}" "$$" > "$DRIVE_WSL_LOCK/owner"
        drive_lock_status=$?
    else
        drive_lock_status=1
    fi
    drive_traps
    if [ -n "$drive_lock_signal" ]; then kill -s "$drive_lock_signal" "$$"; fi
    if [ "$drive_lock_status" != 0 ]; then
        # PIDs are namespace-local. Even a dead local PID cannot prove that a
        # different distro/host has stopped using the image. Never steal locks.
        drive_fail "WSL image locked: $DRIVE_WSL_LOCK. Owner: $(cat "$DRIVE_WSL_LOCK/owner" 2>/dev/null).
After a crash, this may be a stale lock. Stop sessions in ALL distros/hosts,
verify losetup -j '$drive_wsl_img' is empty everywhere, repair the unmounted image
if needed, then remove the lock directory and any wsl-state.partial.* files."
        return 1
    fi
}

drive_wsl_owns_lock() {
    [ "${DRIVE_WSL_LOCK_HELD:-0}" = 1 ] &&
        [ -n "${DRIVE_WSL_TOKEN:-}" ] &&
        [ "$(head -n 1 -- "$DRIVE_WSL_LOCK/owner" 2>/dev/null)" = "$DRIVE_WSL_TOKEN" ]
}

drive_wsl_consent() {
    # Never consume piped CLI input as a sudo consent response.
    if ! { IFS= read -r drive_wsl_consent </dev/tty; } 2>/dev/null; then
        drive_fail 'WSL sudo mount requires a controlling terminal (/dev/tty); launch interactively first.'
        return 1
    fi
    case $drive_wsl_consent in y|Y|yes) return 0;; *) drive_fail 'WSL mount cancelled.';; esac
}

drive_wsl_discover() {
    drive_wsl_shared=$1
    # shellcheck source=launch/lib/wsl-identity.sh
    . "$drive_wsl_shared/launch/lib/wsl-identity.sh" || return 1
    [ -n "$drive_wsl_shared" ] || { drive_fail 'AI-SHARED path required for WSL state discovery.'; return 1; }
    case $(uname -r) in
        *[Mm]icrosoft*|*WSL*)
            case $(uname -r) in *[Mm]icrosoft-standard*|*WSL2*) :;;
                *) drive_fail 'WSL1 is unsupported; convert this distro to WSL2 first.'; return 1;; esac;;
    esac
    if [ -b /dev/disk/by-label/AI-LINUX ]; then
        drive_wsl_native_mount=$(findmnt -rn -S /dev/disk/by-label/AI-LINUX -o TARGET --raw) || drive_wsl_native_mount=
        if [ -n "$drive_wsl_native_mount" ]; then
            drive_decode_mount "$drive_wsl_native_mount"
            return $?
        fi
    fi
    drive_wsl_img="$drive_wsl_shared/state/wsl-state.ext4"
    mkdir -p "$drive_wsl_shared/state" || return 1
    drive_wsl_lock || return 1
    command -v losetup >/dev/null 2>&1 || { drive_fail 'losetup is required for safe WSL image discovery.'; return 1; }
    drive_wsl_attached=$(losetup -j "$drive_wsl_img") || return 1
    [ -z "$drive_wsl_attached" ] || { drive_fail "WSL image already attached; close the other session: $drive_wsl_attached"; return 1; }
    if [ ! -f "$drive_wsl_img" ]; then
        # Accept integer MiB/GiB sizes only, avoiding platform-dependent parsing.
        drive_wsl_size=${PORTABLE_AI_WSL_IMAGE_SIZE:-4G}
        case $drive_wsl_size in
            *M) drive_wsl_units=1048576;; *G) drive_wsl_units=1073741824;;
            *) drive_fail 'PORTABLE_AI_WSL_IMAGE_SIZE must be an integer followed by M or G (default 4G).'; return 1;;
        esac
        drive_wsl_number=${drive_wsl_size%?}
        case $drive_wsl_number in ''|0*|*[!0-9]*|????????*) drive_fail 'Invalid WSL image size.'; return 1;; esac
        drive_wsl_bytes=$((drive_wsl_number * drive_wsl_units))
        [ "$drive_wsl_bytes" -ge 67108864 ] || { drive_fail 'WSL image must be at least 64M.'; return 1; }
        # Direct filesystems only: DrvFS reports v9fs/virtiofs, not FAT32.
        drive_wsl_fs=$(stat -f -c %T -- "$drive_wsl_shared/state") || return 1
        case $drive_wsl_fs in
            vfat|msdos) [ "$drive_wsl_bytes" -lt 4294967296 ] || { drive_fail 'FAT32 cannot hold a 4 GiB file; use exFAT or a smaller PORTABLE_AI_WSL_IMAGE_SIZE.'; return 1; };;
        esac
        drive_wsl_free=$(df -Pk "$drive_wsl_shared/state" | awk 'NR==2 {print $4}')
        case $drive_wsl_free in ''|*[!0-9]*) drive_fail 'Cannot determine free space for WSL image.'; return 1;; esac
        [ "$drive_wsl_free" -ge "$((drive_wsl_bytes / 1024))" ] || { drive_fail 'Not enough free space for WSL image.'; return 1; }
        # The token-owned directory is already unique. Set the partial path
        # before creating it so a signal cannot lose a mktemp return value.
        DRIVE_WSL_PARTIAL=$DRIVE_WSL_LOCK/image.partial
        (umask 077; set -C; : > "$DRIVE_WSL_PARTIAL") || return 1
        printf 'Creating %s drive-resident WSL ext4 image...\n' "$drive_wsl_size" >&2
        truncate -s "$drive_wsl_size" "$DRIVE_WSL_PARTIAL" || { drive_fail 'Image allocation failed (check free space and filesystem file-size limit).'; return 1; }
        mkfs.ext4 -F -q -E "root_owner=$(id -u):$(id -g)" -L AI-WSL-STATE "$DRIVE_WSL_PARTIAL" || return 1
        mv -- "$DRIVE_WSL_PARTIAL" "$drive_wsl_img" || return 1
        DRIVE_WSL_PARTIAL=
    fi

    # Record acquisition intent BEFORE external commands: a signal can arrive
    # after the kernel attaches/mounts but before command substitution returns.
    DRIVE_WSL_ATTACH_ATTEMPT=1
    DRIVE_WSL_BACKEND=udisks
    if command -v udisksctl >/dev/null 2>&1 && drive_wsl_diskseq_available; then
        # Defer launcher signals until the attachment generation is recorded.
        drive_wsl_acquire_signal=
        trap 'drive_wsl_acquire_signal=INT' INT
        trap 'drive_wsl_acquire_signal=TERM' TERM
        trap 'drive_wsl_acquire_signal=HUP' HUP
        drive_wsl_uout=$(udisksctl loop-setup -f "$drive_wsl_img")
        DRIVE_WSL_LOOP_DEV=$(printf '%s\n' "$drive_wsl_uout" | sed -n 's/.* as \(\/dev\/loop[0-9]*\)\..*/\1/p')
        if [ -n "$DRIVE_WSL_LOOP_DEV" ]; then
            DRIVE_WSL_IDENTITY=$(drive_wsl_identity_capture "$drive_wsl_img" "$DRIVE_WSL_LOOP_DEV") || {
                drive_traps
                drive_fail 'Cannot verify loop diskseq before udisks mount; attachment retained for manual recovery.'; return 1;
            }
            drive_traps
            [ -z "$drive_wsl_acquire_signal" ] || kill -s "$drive_wsl_acquire_signal" "$$"
            case $DRIVE_WSL_IDENTITY in diskseq:*) :;; *) drive_fail 'Safe udisks teardown requires diskseq; use the sudo backend for the pinned mount-ID fallback.'; return 1;; esac
            udisksctl mount -b "$DRIVE_WSL_LOOP_DEV" -o nosuid,nodev >&2 || return 1
            DRIVE_WSL_MOUNTED=1
            drive_wsl_target=$(findmnt -rn -S "$DRIVE_WSL_LOOP_DEV" -o TARGET --raw) || return 1
            [ -n "$drive_wsl_target" ] || return 1
            drive_decode_mount "$drive_wsl_target" || return 1
            DRIVE_WSL_MOUNT_TARGET=$drive_discovered
            return 0
        fi
        drive_traps
        [ -z "$drive_wsl_acquire_signal" ] || kill -s "$drive_wsl_acquire_signal" "$$"
        # Do not fall back after an ambiguous/partial udisks attachment.
        drive_wsl_attached=$(losetup -j "$drive_wsl_img") || return 1
        [ -z "$drive_wsl_attached" ] || return 1
    fi
    DRIVE_WSL_BACKEND=sudo
    printf 'WSL state requires sudo to attach, mount and later unmount the image. Continue? [y/N] ' >&2
    drive_wsl_consent || return 1
    DRIVE_WSL_TMP_MOUNT=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/ai-drive-wsl.XXXXXX") || return 1
    if [ -L "$DRIVE_WSL_TMP_MOUNT" ] || [ ! -d "$DRIVE_WSL_TMP_MOUNT" ] ||
        [ "$(stat -c %u -- "$DRIVE_WSL_TMP_MOUNT")" != "$(id -u)" ]; then
        drive_fail 'Unsafe WSL mountpoint.'; return 1
    fi
    DRIVE_WSL_MOUNT_TARGET=$DRIVE_WSL_TMP_MOUNT
    DRIVE_WSL_WATCHDOG=1
    drive_wsl_acquire_signal=
    trap 'drive_wsl_acquire_signal=INT' INT
    trap 'drive_wsl_acquire_signal=TERM' TERM
    trap 'drive_wsl_acquire_signal=HUP' HUP
    drive_wsl_acquired=$(sudo bash "$drive_wsl_shared/launch/lib/wsl-watchdog.sh" acquire "$$" "$drive_wsl_img" "$DRIVE_WSL_MOUNT_TARGET" "$DRIVE_WSL_LOCK" "$DRIVE_WSL_TOKEN") || { drive_traps; return 1; }
    DRIVE_WSL_LOOP_DEV=${drive_wsl_acquired%%'
'*}
    DRIVE_WSL_IDENTITY=${drive_wsl_acquired#*'
'}
    [ -n "$DRIVE_WSL_LOOP_DEV" ] && [ "$DRIVE_WSL_IDENTITY" != "$drive_wsl_acquired" ] || return 1
    DRIVE_WSL_MOUNTED=1
    drive_traps
    [ -z "$drive_wsl_acquire_signal" ] || kill -s "$drive_wsl_acquire_signal" "$$"
    drive_discovered=$DRIVE_WSL_MOUNT_TARGET
}

drive_wsl_unmount() {
    # Teardown follows our in-memory acquisition state, never mutable lock data.
    [ "${DRIVE_WSL_LOCK_HELD:-0}" = 1 ] || return 0
    drive_wsl_cleanup_status=0
    if [ "${DRIVE_WSL_ATTACH_ATTEMPT:-0}" = 1 ]; then
        drive_wsl_attached=$(losetup -j "$drive_wsl_img") || drive_wsl_cleanup_status=1
        if [ -z "$drive_wsl_attached" ] && [ -n "${DRIVE_WSL_LOOP_DEV:-}" ] &&
            ! drive_wsl_identity_inactive "$DRIVE_WSL_LOOP_DEV"; then
            drive_fail 'Image mapping disappeared but the recorded loop is still active or unreadable; refusing to declare teardown complete.'
            drive_wsl_cleanup_status=1
        fi
        if [ -n "$drive_wsl_attached" ]; then
            if [ -z "${DRIVE_WSL_LOOP_DEV:-}" ] || [ -z "${DRIVE_WSL_IDENTITY:-}" ]; then
                drive_fail 'Attachment identity was not recorded; refusing teardown. Keep the drive connected for watchdog/manual recovery.'
                drive_wsl_cleanup_status=1
            elif [ "$DRIVE_WSL_BACKEND" = sudo ]; then
                if [ -z "${drive_cleanup_signal:-}" ]; then sudo -v || drive_wsl_cleanup_status=1; fi
                sudo -n bash "$drive_wsl_shared/launch/lib/wsl-watchdog.sh" cleanup "$$" "$drive_wsl_img" "$DRIVE_WSL_MOUNT_TARGET" "$DRIVE_WSL_LOCK" "$DRIVE_WSL_TOKEN" "$DRIVE_WSL_LOOP_DEV" '' '' '' "$DRIVE_WSL_IDENTITY" || drive_wsl_cleanup_status=1
            else
                sync || drive_wsl_cleanup_status=1
                if drive_wsl_identity_verify "$drive_wsl_img" "$DRIVE_WSL_LOOP_DEV" "$DRIVE_WSL_IDENTITY"; then
                    if [ "${DRIVE_WSL_MOUNTED:-0}" = 1 ] || findmnt -rn -S "$DRIVE_WSL_LOOP_DEV" >/dev/null; then
                        udisksctl unmount -b "$DRIVE_WSL_LOOP_DEV" || drive_wsl_cleanup_status=1
                    fi
                    if [ "$drive_wsl_cleanup_status" = 0 ]; then
                        if drive_wsl_identity_verify "$drive_wsl_img" "$DRIVE_WSL_LOOP_DEV" "$DRIVE_WSL_IDENTITY"; then
                            udisksctl loop-delete -b "$DRIVE_WSL_LOOP_DEV" || drive_wsl_cleanup_status=1
                        else drive_wsl_cleanup_status=1; fi
                    fi
                else
                    drive_fail 'Loop attachment identity changed or is unreadable; refusing teardown.'
                    drive_wsl_cleanup_status=1
                fi
            fi
            drive_wsl_attached=$(losetup -j "$drive_wsl_img") || drive_wsl_cleanup_status=1
            [ -z "$drive_wsl_attached" ] || drive_wsl_cleanup_status=1
        fi
    fi
    if [ -n "${DRIVE_WSL_PARTIAL:-}" ] && drive_wsl_owns_lock; then
        rm -f -- "$DRIVE_WSL_PARTIAL" || drive_wsl_cleanup_status=1
    fi
    if [ "$drive_wsl_cleanup_status" != 0 ]; then
        if [ "${DRIVE_WSL_WATCHDOG:-0}" = 1 ]; then
            printf 'Privileged WSL watchdog will retry teardown after this launcher exits. Keep the drive connected until the session lock disappears.\n' >&2
        fi
        drive_fail "WSL cleanup failed: do NOT unplug the drive. Lock retained: $DRIVE_WSL_LOCK.
Check findmnt -S '${DRIVE_WSL_LOOP_DEV:-unknown}' and losetup -j '$drive_wsl_img'.
Unmount with sudo umount '${DRIVE_WSL_MOUNT_TARGET:-${DRIVE_WSL_LOOP_DEV:-unknown}}', then sudo losetup -d '${DRIVE_WSL_LOOP_DEV:-unknown}'."
        return 1
    fi
    if [ -n "${DRIVE_WSL_TMP_MOUNT:-}" ]; then
        [ ! -d "$DRIVE_WSL_TMP_MOUNT" ] || rmdir -- "$DRIVE_WSL_TMP_MOUNT" 2>/dev/null || printf 'Warning: empty WSL mountpoint remains: %s\n' "$DRIVE_WSL_TMP_MOUNT" >&2
    fi
    if ! drive_wsl_owns_lock; then
        drive_fail "WSL image teardown completed, but its lock token changed or cannot be read. Lock left untouched: $DRIVE_WSL_LOCK. The image is detached; the lock was left for manual recovery."
        return 1
    fi
    rm -f "$DRIVE_WSL_LOCK/owner" && rmdir "$DRIVE_WSL_LOCK" || return 1
    DRIVE_WSL_LOCK_HELD=0
    unset DRIVE_WSL_LOOP_DEV DRIVE_WSL_MOUNT_TARGET DRIVE_WSL_MOUNTED DRIVE_WSL_ATTACH_ATTEMPT DRIVE_WSL_TMP_MOUNT
}

drive_discover() {
    case $1 in
        linux)
            if drive_is_wsl; then
                drive_wsl_discover "${2:-${drive_shared:-}}"
                return $?
            fi
            drive_device=/dev/disk/by-label/AI-LINUX
            drive_mount=$(findmnt -rn -S "$drive_device" -o TARGET --raw) || drive_mount=
            if [ -z "$drive_mount" ]; then
                if command -v udisksctl >/dev/null 2>&1; then
                    udisksctl mount -b "$drive_device" >&2 || :
                    drive_mount=$(findmnt -rn -S "$drive_device" -o TARGET --raw) || drive_mount=
                fi
            fi
            [ -n "$drive_mount" ] || { drive_fail 'Mount AI-LINUX with: udisksctl mount -b /dev/disk/by-label/AI-LINUX'; return 1; }
            ;;
        darwin)
            drive_mount=/Volumes/AI-MAC
            if [ ! -d "$drive_mount" ]; then
                drive_mount=$(diskutil info AI-MAC | sed -n 's/^ *Mount Point: *//p') || return 1
            fi
            [ -d "$drive_mount" ] || { drive_fail 'Mount AI-MAC with: diskutil mount AI-MAC'; return 1; }
            ;;
        *) drive_fail "Unsupported OS: $1"; return 1 ;;
    esac
    # Multiple matching mounts are ambiguous; never silently select one.
    case $drive_mount in *'
'*) drive_fail 'Multiple native volumes found; detach duplicate labels.'; return 1;; esac
    # findmnt --raw hex-escapes whitespace and backslashes. Bash's printf
    # decodes those bytes without evaluating any shell code.
    if [ "$1" = linux ]; then drive_decode_mount "$drive_mount" || return 1; else drive_discovered=$drive_mount; fi
    printf '%s\n' "$drive_discovered"
}

drive_arch() {
    case $(uname -m) in
        x86_64|amd64) printf 'x64\n';;
        arm64|aarch64) printf 'arm64\n';;
        *) drive_fail 'Unsupported CPU architecture'; return 1;;
    esac
}

drive_environment() {
    # $1 shared, $2 native, $3 os-arch. No change to the calling user's shell.
    drive_shared=$1 drive_native=$2 drive_bin=$2/bin/$3
    if drive_is_wsl; then
        if [ ! -w "$drive_native" ]; then
            drive_fail "WSL image root is not writable by this user. While mounted, repair ownership with: sudo chown \"$(id -u):$(id -g)\" \"$drive_native\""
            return 1
        fi
        if [ "${drive_wsl_clis_ready:-0}" != 1 ]; then
            DRIVE_CLAUDE_EXE='' DRIVE_CLAUDE_BIN_DIR='' DRIVE_CODEX_EXE='' DRIVE_CODEX_BIN_DIR=''
            if drive_resolve_wsl_cli claude >/dev/null; then
                # shellcheck disable=SC2034 # Child PATH in session.sh.
                DRIVE_CLAUDE_EXE=$drive_resolved_cli DRIVE_CLAUDE_BIN_DIR=$drive_resolved_cli_dir
            fi
            if drive_resolve_wsl_cli codex >/dev/null; then
                # shellcheck disable=SC2034 # Child PATH in session.sh.
                DRIVE_CODEX_EXE=$drive_resolved_cli DRIVE_CODEX_BIN_DIR=$drive_resolved_cli_dir
            fi
            drive_wsl_clis_ready=1
        fi
        export DRIVE_CLAUDE_EXE DRIVE_CODEX_EXE
    else
        [ -d "$drive_bin" ] || { drive_fail "Missing binaries: $drive_bin; provision this architecture first."; return 1; }
        DRIVE_CLAUDE_EXE="$drive_bin/claude"
        DRIVE_CODEX_EXE="$drive_bin/codex/bin/codex"
        export DRIVE_CLAUDE_EXE DRIVE_CODEX_EXE
    fi
    umask 077
    for drive_dir in state/claude state/codex state/xdg/config state/xdg/cache state/xdg/data state/xdg/state state/home state/dashboard tmp; do
        mkdir -p "$drive_native/$drive_dir" || { drive_fail "Cannot create state on $drive_native. See START-HERE.md."; return 1; }
        [ -w "$drive_native/$drive_dir" ] || { drive_fail "Cannot write $drive_native/$drive_dir. See START-HERE.md."; return 1; }
    done
    export CLAUDE_CONFIG_DIR="$drive_native/state/claude" CLAUDE_CODE_TMPDIR="$drive_native/tmp"
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN OPENAI_API_KEY ANTHROPIC_BASE_URL OPENAI_BASE_URL CLAUDE_CODE_OAUTH_TOKEN
    export DISABLE_AUTOUPDATER=1 DISABLE_UPDATES=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1
    export CODEX_HOME="$drive_native/state/codex" CODEX_SQLITE_HOME="$drive_native/state/codex"
    export TMPDIR="$drive_native/tmp" TEMP="$drive_native/tmp" TMP="$drive_native/tmp"
    export XDG_CONFIG_HOME="$drive_native/state/xdg/config" XDG_CACHE_HOME="$drive_native/state/xdg/cache"
    export XDG_DATA_HOME="$drive_native/state/xdg/data" XDG_STATE_HOME="$drive_native/state/xdg/state"
    export HOME="$drive_native/state/home"
    if drive_is_wsl; then
        export PORTABLE_AI_CLAUDE_EXECUTABLE="$DRIVE_CLAUDE_EXE" PORTABLE_AI_NO_OPEN=1
    else
        export PORTABLE_AI_DATA_DIR="$drive_native/state/dashboard" PORTABLE_AI_RUNTIME_DIR="$drive_native/tools/dashboard-runtime"
        export PORTABLE_AI_CLAUDE_EXECUTABLE="$DRIVE_CLAUDE_EXE" PORTABLE_AI_NO_OPEN=1
        export PATH="$drive_bin:$drive_bin/codex/bin:$drive_bin/codex/codex-path:$drive_bin/node/bin:$PATH"
    fi
    if [ -f "$drive_shared/credentials/claude-oauth-token" ]; then
        CLAUDE_CODE_OAUTH_TOKEN=$(tr -d '\r\n' < "$drive_shared/credentials/claude-oauth-token") || return 1
        export CLAUDE_CODE_OAUTH_TOKEN
    fi
}

drive_codex_config() {
    # Launcher owns these invariants; other settings can live in project config.
    cat > "$CODEX_HOME/config.toml" <<'CONFIG'
cli_auth_credentials_store = "file"
check_for_update_on_startup = false
[analytics]
enabled = false
[feedback]
enabled = false
CONFIG
}

drive_lock() {
    mkdir -p "$drive_shared/credentials" || return 1
    drive_lock_path=$drive_shared/credentials/codex-auth.lock
    # Atomic directory creation works on exFAT across the three operating systems.
    if ! mkdir "$drive_lock_path" 2>/dev/null; then
        drive_fail "Codex is locked: $drive_lock_path. Close the other session. After a crash, verify no session remains on any host before removing this directory."
        return 1
    fi
    printf '%s\n' "$(hostname) $$" > "$drive_lock_path/owner"
}

drive_auth_in() {
    drive_auth=$drive_shared/credentials/codex-auth.json
    if [ -f "$drive_auth" ]; then
        cp -p "$drive_auth" "$CODEX_HOME/auth.json" || return 1
    else
        # Absence of the authoritative cache must not resurrect stale local auth.
        rm -f "$CODEX_HOME/auth.json" || return 1
    fi
}

drive_auth_out() {
    drive_auth=$drive_shared/credentials/codex-auth.json
    if [ -f "$CODEX_HOME/auth.json" ] && { [ ! -f "$drive_auth" ] || [ "$CODEX_HOME/auth.json" -nt "$drive_auth" ]; }; then
        cp -p "$CODEX_HOME/auth.json" "$drive_lock_path/auth.next" && mv -f "$drive_lock_path/auth.next" "$drive_auth" || return 1
        chmod 600 "$drive_auth" 2>/dev/null || :
    fi
}

drive_unlock() {
    rm -f "$drive_lock_path/owner"
    rmdir "$drive_lock_path"
}
