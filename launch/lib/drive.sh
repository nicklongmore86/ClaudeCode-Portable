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
    drive_target_cli=$1
    drive_resolved_cli=
    drive_orig_ifs=$IFS
    IFS=:
    for drive_dir_entry in $PATH; do
        IFS=$drive_orig_ifs
        [ -n "$drive_dir_entry" ] || continue
        drive_check_path="$drive_dir_entry/$drive_target_cli"
        if [ -f "$drive_check_path" ] && [ -x "$drive_check_path" ]; then
            case "$drive_check_path" in
                *.exe|*.cmd|*.bat|/mnt/*) continue;;
                *)
                    drive_resolved_cli=$drive_check_path
                    break
                    ;;
            esac
        fi
    done
    IFS=$drive_orig_ifs
    if [ -n "$drive_resolved_cli" ]; then
        printf '%s\n' "$drive_resolved_cli"
        return 0
    fi
    return 1
}

drive_wsl_discover() {
    drive_wsl_shared=$1
    [ -n "$drive_wsl_shared" ] || { drive_fail 'AI-SHARED path required for WSL state discovery.'; return 1; }

    if [ -b /dev/disk/by-label/AI-LINUX ]; then
        drive_wsl_native_mount=$(findmnt -rn -S /dev/disk/by-label/AI-LINUX -o TARGET --raw 2>/dev/null) || drive_wsl_native_mount=
        if [ -n "$drive_wsl_native_mount" ]; then
            printf '%s\n' "$drive_wsl_native_mount"
            return 0
        fi
    fi

    drive_wsl_img="$drive_wsl_shared/state/wsl-state.ext4"
    if [ ! -f "$drive_wsl_img" ]; then
        mkdir -p "$drive_wsl_shared/state" || { drive_fail "Cannot create directory $drive_wsl_shared/state."; return 1; }
        printf 'Creating drive-resident WSL ext4 state image (wsl-state.ext4)...\n' >&2
        truncate -s 4G "$drive_wsl_img" || { drive_fail "Failed to allocate 4GB sparse image: $drive_wsl_img"; return 1; }
        mkfs.ext4 -F -q -L AI-WSL-STATE "$drive_wsl_img" || { rm -f "$drive_wsl_img"; drive_fail "mkfs.ext4 failed on $drive_wsl_img"; return 1; }
    fi

    drive_wsl_cur_mount=$(findmnt -rn -S "$drive_wsl_img" -o TARGET --raw 2>/dev/null || findmnt -rn -S /dev/disk/by-label/AI-WSL-STATE -o TARGET --raw 2>/dev/null || :)
    if [ -n "$drive_wsl_cur_mount" ]; then
        printf '%s\n' "$drive_wsl_cur_mount"
        return 0
    fi

    if command -v udisksctl >/dev/null 2>&1; then
        drive_wsl_uout=$(udisksctl loop-setup -f "$drive_wsl_img" 2>/dev/null || :)
        if [ -n "$drive_wsl_uout" ]; then
            drive_wsl_udev=$(printf '%s\n' "$drive_wsl_uout" | sed -n 's/.* as \(\/dev\/[^.]*\)\..*/\1/p')
            if [ -n "$drive_wsl_udev" ]; then
                drive_wsl_mout=$(udisksctl mount -b "$drive_wsl_udev" 2>/dev/null || :)
                if [ -n "$drive_wsl_mout" ]; then
                    drive_wsl_target_mount=$(printf '%s\n' "$drive_wsl_mout" | sed -e 's/^Mounted [^ ]* at //' -e 's/\.$//')
                    DRIVE_WSL_LOOP_DEV="$drive_wsl_udev"
                    DRIVE_WSL_MOUNT_TARGET="$drive_wsl_target_mount"
                    export DRIVE_WSL_LOOP_DEV DRIVE_WSL_MOUNT_TARGET
                    printf '%s\n' "$drive_wsl_target_mount"
                    return 0
                fi
                udisksctl loop-delete -b "$drive_wsl_udev" 2>/dev/null || :
            fi
        fi
    fi

    drive_wsl_tmp_mnt="/tmp/ai-drive-wsl-$(id -u)"
    mkdir -p "$drive_wsl_tmp_mnt" 2>/dev/null || :
    if mount -o loop "$drive_wsl_img" "$drive_wsl_tmp_mnt" 2>/dev/null; then
        DRIVE_WSL_MOUNT_TARGET="$drive_wsl_tmp_mnt"
        DRIVE_WSL_SUDO_MOUNT=0
        export DRIVE_WSL_MOUNT_TARGET DRIVE_WSL_SUDO_MOUNT
        printf '%s\n' "$drive_wsl_tmp_mnt"
        return 0
    fi
    if sudo -n mount -o loop "$drive_wsl_img" "$drive_wsl_tmp_mnt" 2>/dev/null || sudo mount -o loop "$drive_wsl_img" "$drive_wsl_tmp_mnt" 2>/dev/null; then
        DRIVE_WSL_MOUNT_TARGET="$drive_wsl_tmp_mnt"
        DRIVE_WSL_SUDO_MOUNT=1
        sudo chown "$(id -u):$(id -g)" "$drive_wsl_tmp_mnt" 2>/dev/null || :
        export DRIVE_WSL_MOUNT_TARGET DRIVE_WSL_SUDO_MOUNT
        printf '%s\n' "$drive_wsl_tmp_mnt"
        return 0
    fi

    rmdir "$drive_wsl_tmp_mnt" 2>/dev/null || :
    drive_fail "Could not mount $drive_wsl_img. Mount with: sudo mount -o loop \"$drive_wsl_img\" /mnt/ai-wsl-state"
    return 1
}

drive_wsl_unmount() {
    if [ -n "${DRIVE_WSL_LOOP_DEV:-}" ]; then
        if command -v udisksctl >/dev/null 2>&1; then
            udisksctl unmount -b "$DRIVE_WSL_LOOP_DEV" 2>/dev/null || :
            udisksctl loop-delete -b "$DRIVE_WSL_LOOP_DEV" 2>/dev/null || :
        fi
        unset DRIVE_WSL_LOOP_DEV DRIVE_WSL_MOUNT_TARGET
    elif [ -n "${DRIVE_WSL_MOUNT_TARGET:-}" ]; then
        if [ "${DRIVE_WSL_SUDO_MOUNT:-0}" -eq 1 ]; then
            sudo umount "$DRIVE_WSL_MOUNT_TARGET" 2>/dev/null || :
        else
            umount "$DRIVE_WSL_MOUNT_TARGET" 2>/dev/null || :
        fi
        rmdir "$DRIVE_WSL_MOUNT_TARGET" 2>/dev/null || :
        unset DRIVE_WSL_MOUNT_TARGET DRIVE_WSL_SUDO_MOUNT
    fi
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
    if [ "$1" = linux ]; then printf '%b\n' "$drive_mount"; else printf '%s\n' "$drive_mount"; fi
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
        DRIVE_CLAUDE_EXE=$(drive_resolve_wsl_cli claude) || DRIVE_CLAUDE_EXE=
        DRIVE_CODEX_EXE=$(drive_resolve_wsl_cli codex) || DRIVE_CODEX_EXE=
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
