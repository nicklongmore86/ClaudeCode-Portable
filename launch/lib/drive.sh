#!/bin/sh
# shellcheck disable=SC3013
# -nt is supported by the system shells on both supported Unix platforms.
# Shared POSIX helpers. Call drive_environment only inside a child/subshell.
drive_fail() { printf '%s\n' "$*" >&2; return 1; }

drive_discover() {
    case $1 in
        linux)
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
    [ -d "$drive_bin" ] || { drive_fail "Missing binaries: $drive_bin; provision this architecture first."; return 1; }
    umask 077
    for drive_dir in state/claude state/codex state/xdg/config state/xdg/cache state/xdg/data state/xdg/state state/home state/dashboard tmp; do
        mkdir -p "$drive_native/$drive_dir" || { drive_fail "Cannot create state on AI-LINUX/AI-MAC. Transfer ownership to UID $(id -u) on the prep machine; see START-HERE.md."; return 1; }
        [ -w "$drive_native/$drive_dir" ] || { drive_fail "Cannot write $drive_native/$drive_dir. On the prep machine, transfer ownership to UID $(id -u); see START-HERE.md."; return 1; }
    done
    export CLAUDE_CONFIG_DIR="$drive_native/state/claude" CLAUDE_CODE_TMPDIR="$drive_native/tmp"
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN OPENAI_API_KEY ANTHROPIC_BASE_URL OPENAI_BASE_URL CLAUDE_CODE_OAUTH_TOKEN
    export DISABLE_AUTOUPDATER=1 DISABLE_UPDATES=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1
    export CODEX_HOME="$drive_native/state/codex" CODEX_SQLITE_HOME="$drive_native/state/codex"
    export TMPDIR="$drive_native/tmp" TEMP="$drive_native/tmp" TMP="$drive_native/tmp"
    export XDG_CONFIG_HOME="$drive_native/state/xdg/config" XDG_CACHE_HOME="$drive_native/state/xdg/cache"
    export XDG_DATA_HOME="$drive_native/state/xdg/data" XDG_STATE_HOME="$drive_native/state/xdg/state"
    export HOME="$drive_native/state/home"
    export PORTABLE_AI_DATA_DIR="$drive_native/state/dashboard" PORTABLE_AI_RUNTIME_DIR="$drive_native/tools/dashboard-runtime"
    export PORTABLE_AI_CLAUDE_EXECUTABLE="$drive_bin/claude" PORTABLE_AI_NO_OPEN=1
    export PATH="$drive_bin:$drive_bin/codex/bin:$drive_bin/codex/codex-path:$drive_bin/node/bin:$PATH"
    if [ -f "$drive_shared/credentials/claude-oauth-token" ]; then
        CLAUDE_CODE_OAUTH_TOKEN=$(cat "$drive_shared/credentials/claude-oauth-token") || return 1
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
