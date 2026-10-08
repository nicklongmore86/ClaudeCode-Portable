#!/bin/bash
# shellcheck disable=SC2317,SC2154
# Traps call cleanup functions; drive.sh supplies the shared variables.
# Bash job control provides a separate process group on Linux and macOS.
# Foregrounding preserves interactive terminal input; cleanup covers descendants
# remaining in the group after the CLI exits, including dashboard children.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _session_lib_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null) || _session_lib_dir=
    if [ -n "$_session_lib_dir" ] && [ -f "$_session_lib_dir/omnigent-host.sh" ]; then
        # shellcheck source=launch/lib/omnigent-host.sh
        . "$_session_lib_dir/omnigent-host.sh"
    fi
    unset _session_lib_dir
fi
drive_cleanup() {
    if [ -n "${drive_group_file:-}" ] && [ -f "$drive_group_file" ]; then
        drive_child=$(cat "$drive_group_file")
        case $drive_child in
            ''|*[!0-9]*) ;;
            *)
                kill -TERM -- "-$drive_child" 2>/dev/null || :
                drive_poll=0
                while kill -0 -- "-$drive_child" 2>/dev/null && [ "$drive_poll" -lt 20 ]; do
                    sleep 0.1
                    drive_poll=$((drive_poll + 1))
                done
                if kill -0 -- "-$drive_child" 2>/dev/null; then
                    kill -KILL -- "-$drive_child" 2>/dev/null || :
                fi
                ;;
        esac
        if [ -n "${drive_supervisor:-}" ]; then
            kill -TERM "$drive_supervisor" 2>/dev/null || :
            wait "$drive_supervisor" 2>/dev/null || :
        fi
        rm -f "$drive_group_file"
        drive_group_file=
        drive_supervisor=
    fi
}

drive_codex_end() {
    if [ "${drive_locked:-0}" -eq 1 ]; then
        if [ "${drive_auth_ready:-0}" -eq 1 ] && ! drive_auth_out; then
            drive_locked=0
            printf 'Auth sync failed; lock retained for recovery: %s\n' "$drive_lock_path" >&2
            return 1
        fi
        drive_locked=0
        drive_unlock || return 1
    fi
}

drive_finish() {
    drive_exit_status=$?
    trap - EXIT INT TERM HUP
    drive_cleanup
    drive_codex_end || drive_exit_status=1
    drive_wsl_unmount
    exit "$drive_exit_status"
}

drive_traps() {
    trap drive_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
}

drive_run() {
    drive_traps
    drive_group_file=$(mktemp "${TMPDIR:?}/drive-session.XXXXXX") || return 1
    # The outer shell waits interruptibly; fg itself defers signal traps. The
    # inner shell handles terminal foreground ownership for the CLI's group.
    (
        trap - EXIT INT TERM HUP
        set -m
        "$@" <&0 &
        printf '%s\n' "$!" > "$drive_group_file"
        fg %+ >/dev/null
    ) <&0 &
    drive_supervisor=$!
    wait "$drive_supervisor"
    drive_run_status=$?
    drive_cleanup
    return "$drive_run_status"
}

drive_codex() {
    drive_lock || return 1
    drive_locked=1
    drive_auth_ready=0
    drive_traps
    if ! drive_auth_in || ! drive_codex_config; then
        drive_codex_end
        return 1
    fi
    drive_auth_ready=1
    drive_run "${DRIVE_CODEX_EXE:-$drive_bin/codex/bin/codex}" --no-daemon "$@"
    drive_codex_status=$?
    drive_codex_end || return 1
    return "$drive_codex_status"
}

drive_omnigent() {
    case $drive_os in
        linux|darwin) ;;
        *)
            drive_fail "Omnigent Host is currently supported on Linux and macOS only."
            return 1
            ;;
    esac

    if ! command -v drive_omnigent_environment >/dev/null 2>&1; then
        if [ -n "${drive_entry:-}" ] && [ -f "$(dirname -- "$drive_entry")/lib/omnigent-host.sh" ]; then
            # shellcheck source=launch/lib/omnigent-host.sh
            . "$(dirname -- "$drive_entry")/lib/omnigent-host.sh"
        elif [ -n "${drive_shared:-}" ] && [ -f "$drive_shared/launch/lib/omnigent-host.sh" ]; then
            # shellcheck source=launch/lib/omnigent-host.sh
            . "$drive_shared/launch/lib/omnigent-host.sh"
        else
            drive_fail "Cannot find omnigent-host.sh library."
            return 1
        fi
    fi

    drive_python="$drive_native/bin/$drive_target/python"
    drive_omnigent_environment "$drive_native" "$drive_target" || return 1

    drive_server_url=$(drive_omnigent_server_url "$drive_shared" "$@") || return 1
    drive_omnigent_host_identity "$drive_shared" "$drive_python" "$drive_os" || return 1

    drive_lock || return 1
    drive_locked=1
    drive_auth_ready=0
    drive_traps
    if ! drive_auth_in || ! drive_codex_config; then
        drive_codex_end
        return 1
    fi
    drive_auth_ready=1

    drive_filtered_args=()
    drive_skip=0
    for drive_arg in "$@"; do
        if [ "$drive_skip" -eq 1 ]; then
            drive_skip=0
            continue
        fi
        case "$drive_arg" in
            --server=*)
                ;;
            --server)
                drive_skip=1
                ;;
            http://*|https://*|ws://*|wss://*)
                ;;
            *)
                drive_filtered_args+=("$drive_arg")
                ;;
        esac
    done

    drive_run "$drive_python/bin/python3" -m omnigent.cli host "$drive_server_url" --no-open "${drive_filtered_args[@]}"
    drive_omnigent_status=$?
    drive_codex_end || return 1
    return "$drive_omnigent_status"
}

drive_login() {
    printf 'Login: 1 Claude subscription  2 Codex device login  3 Codex browser login  4 Omnigent server URL\n'
    IFS= read -r drive_choice || return 1
    case $drive_choice in
        1)
            unset CLAUDE_CODE_OAUTH_TOKEN
            if drive_is_wsl && [ -z "${DRIVE_CLAUDE_EXE:-}" ]; then
                drive_fail "Linux 'claude' CLI not found in WSL. Install Claude Code inside WSL Ubuntu first."
                return 1
            fi
            drive_run "${DRIVE_CLAUDE_EXE:-$drive_bin/claude}" setup-token || return 1
            printf 'Paste the token (hidden): ' >&2
            IFS= read -r -s drive_token || return 1
            printf '\n' >&2
            drive_token=$(printf '%s' "$drive_token" | tr -d '\r\n') || return 1
            [ -n "$drive_token" ] || { drive_fail 'Empty token; nothing saved.'; return 1; }
            mkdir -p "$drive_shared/credentials" || return 1
            printf '%s' "$drive_token" > "$drive_shared/credentials/claude-oauth-token.next" || return 1
            unset drive_token
            chmod 600 "$drive_shared/credentials/claude-oauth-token.next" 2>/dev/null || :
            mv -f "$drive_shared/credentials/claude-oauth-token.next" "$drive_shared/credentials/claude-oauth-token"
            ;;
        2)
            if drive_is_wsl && [ -z "${DRIVE_CODEX_EXE:-}" ]; then
                drive_fail "Linux 'codex' CLI not found in WSL. Install Codex inside WSL Ubuntu first."
                return 1
            fi
            drive_codex login --device-auth
            ;;
        3)
            if drive_is_wsl && [ -z "${DRIVE_CODEX_EXE:-}" ]; then
                drive_fail "Linux 'codex' CLI not found in WSL. Install Codex inside WSL Ubuntu first."
                return 1
            fi
            drive_codex login
            ;;
        4)
            if ! command -v drive_omnigent_setup_server_url >/dev/null 2>&1; then
                if [ -n "${drive_entry:-}" ] && [ -f "$(dirname -- "$drive_entry")/lib/omnigent-host.sh" ]; then
                    # shellcheck source=launch/lib/omnigent-host.sh
                    . "$(dirname -- "$drive_entry")/lib/omnigent-host.sh"
                elif [ -n "${drive_shared:-}" ] && [ -f "$drive_shared/launch/lib/omnigent-host.sh" ]; then
                    # shellcheck source=launch/lib/omnigent-host.sh
                    . "$drive_shared/launch/lib/omnigent-host.sh"
                fi
            fi
            drive_omnigent_setup_server_url "$drive_shared"
            ;;
        *) drive_fail 'Unknown login option';;
    esac
}

drive_main() {
    set +x # Never trace credentials, including when called with bash -x.
    drive_os=$1 drive_entry=$2
    shift 2
    drive_shared=$(CDPATH='' cd -- "$(dirname -- "$drive_entry")/.." && pwd -P) || exit 1
    drive_native=$(drive_discover "$drive_os" "$drive_shared") || exit 1
    drive_target=$drive_os-$(drive_arch) || exit 1
    drive_host_home=$HOME
    drive_environment "$drive_shared" "$drive_native" "$drive_target" || exit 1
    drive_action=${1:-menu}
    [ "$#" -eq 0 ] || shift
    while :; do
        if [ "$drive_action" = menu ]; then
            printf '\n1 Claude Code\n2 Codex\n3 Dashboard\n4 Omnigent Host\n5 Login setup\n6 Audit\n7 Exit\nChoose: '
            IFS= read -r drive_selected || exit 0
        else drive_selected=$drive_action; fi
        case $drive_selected in
            1|claude)
                if drive_is_wsl && [ -z "${DRIVE_CLAUDE_EXE:-}" ]; then
                    drive_fail "Linux 'claude' CLI not found. Install Claude Code inside WSL Ubuntu (e.g. 'npm install -g @anthropic-ai/claude-code'). Note: Windows .exe/.cmd shims are not used in WSL mode."
                else
                    drive_run "${DRIVE_CLAUDE_EXE:-$drive_bin/claude}" "$@"
                fi
                ;;
            2|codex)
                if drive_is_wsl && [ -z "${DRIVE_CODEX_EXE:-}" ]; then
                    drive_fail "Linux 'codex' CLI not found. Install Codex inside WSL Ubuntu (e.g. 'npm install -g @openai/codex'). Note: Windows .exe/.cmd shims are not used in WSL mode."
                else
                    drive_codex "$@"
                fi
                ;;
            3|dashboard)
                if drive_is_wsl; then
                    drive_fail "Dashboard is not supported in WSL mode. Use launch/windows.cmd for the dashboard on Windows."
                else
                    drive_run "$drive_bin/node/bin/node" "$drive_native/tools/dashboard/tools/launcher.mjs" dashboard "$@"
                fi
                ;;
            4|omnigent|omnigent-host|host)
                drive_omnigent "$@"
                ;;
            5|login) drive_login;;
            6|audit)
                if [ "$drive_action" = menu ]; then
                    printf 'Audit: 1 Before snapshot  2 After snapshot  3 Diff\n'
                    IFS= read -r drive_audit_choice || return 1
                    case $drive_audit_choice in
                        1) HOME=$drive_host_home sh "$drive_shared/tools/audit/audit.sh" snapshot "$drive_shared/logs/before.txt";;
                        2) HOME=$drive_host_home sh "$drive_shared/tools/audit/audit.sh" snapshot "$drive_shared/logs/after.txt";;
                        3) HOME=$drive_host_home sh "$drive_shared/tools/audit/audit.sh" diff "$drive_shared/logs/before.txt" "$drive_shared/logs/after.txt";;
                        *) drive_fail 'Unknown audit option';;
                    esac
                else HOME=$drive_host_home sh "$drive_shared/tools/audit/audit.sh" "$@"; fi
                ;;
            7|exit) exit 0;;
            *) drive_fail 'Choose claude, codex, dashboard, omnigent, login, audit or exit';;
        esac
        drive_result=$?
        [ "$drive_action" = menu ] || exit "$drive_result"
        # Refresh a token saved during this menu session.
        drive_environment "$drive_shared" "$drive_native" "$drive_target" || exit 1
    done
}
