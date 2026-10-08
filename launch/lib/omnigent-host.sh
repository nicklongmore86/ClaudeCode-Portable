#!/bin/sh
# shellcheck disable=SC3013
# Omnigent Host agent helper functions for ClaudeCode-Portable.
# Zero-host-footprint: all state, caches, temp files, and credentials remain on the drive.

drive_omnigent_server_url() {
    drive_shared=$1
    shift
    drive_server_url="${OMNIGENT_SERVER_URL:-}"
    drive_server_file="$drive_shared/credentials/omnigent-server-url"

    # 1. Command-line argument override
    drive_skip_next=0
    for drive_arg in "$@"; do
        if [ "$drive_skip_next" -eq 1 ]; then
            drive_server_url="$drive_arg"
            drive_skip_next=0
            continue
        fi
        case "$drive_arg" in
            --server=*)
                drive_server_url="${drive_arg#--server=}"
                ;;
            --server)
                drive_skip_next=1
                ;;
            http://*|https://*|ws://*|wss://*)
                drive_server_url="$drive_arg"
                ;;
        esac
    done

    # 2. Stored credential file on the drive
    if [ -z "$drive_server_url" ] && [ -f "$drive_server_file" ]; then
        drive_server_url=$(tr -d '\r\n' < "$drive_server_file" | xargs)
    fi

    # 3. Interactive prompt if unset
    if [ -z "$drive_server_url" ]; then
        printf 'Enter Omnigent Server URL (e.g. https://omnigent.example.com): ' >&2
        if IFS= read -r drive_input_url; then
            drive_input_url=$(printf '%s' "$drive_input_url" | tr -d '\r\n' | xargs)
            case "$drive_input_url" in
                http://*|https://*|ws://*|wss://*)
                    drive_server_url="$drive_input_url"
                    mkdir -p "$drive_shared/credentials"
                    printf '%s\n' "$drive_server_url" > "$drive_server_file.next"
                    chmod 600 "$drive_server_file.next" 2>/dev/null || :
                    mv -f "$drive_server_file.next" "$drive_server_file"
                    ;;
                *)
                    drive_fail "Invalid server URL: '$drive_input_url'. Must start with http://, https://, ws://, or wss://"
                    return 1
                    ;;
            esac
        else
            drive_fail 'No Omnigent server URL configured. Set OMNIGENT_SERVER_URL or specify --server <url>.'
            return 1
        fi
    fi

    printf '%s\n' "$drive_server_url"
}

drive_omnigent_setup_server_url() {
    drive_shared=$1
    drive_server_file="$drive_shared/credentials/omnigent-server-url"
    drive_current_url=""
    if [ -f "$drive_server_file" ]; then
        drive_current_url=$(tr -d '\r\n' < "$drive_server_file" | xargs)
    fi
    if [ -n "$drive_current_url" ]; then
        printf 'Current Omnigent server URL: %s\n' "$drive_current_url" >&2
        printf 'Enter new URL (or press Enter to keep current): ' >&2
    else
        printf 'Enter Omnigent Server URL (e.g. https://omnigent.example.com): ' >&2
    fi
    if IFS= read -r drive_new_url; then
        drive_new_url=$(printf '%s' "$drive_new_url" | tr -d '\r\n' | xargs)
        if [ -z "$drive_new_url" ] && [ -n "$drive_current_url" ]; then
            printf 'Keeping current server URL: %s\n' "$drive_current_url" >&2
            return 0
        fi
        case "$drive_new_url" in
            http://*|https://*|ws://*|wss://*)
                mkdir -p "$drive_shared/credentials" || return 1
                printf '%s\n' "$drive_new_url" > "$drive_server_file.next" || return 1
                chmod 600 "$drive_server_file.next" 2>/dev/null || :
                mv -f "$drive_server_file.next" "$drive_server_file" || return 1
                printf 'Omnigent server URL saved: %s\n' "$drive_new_url" >&2
                ;;
            *)
                drive_fail "Invalid server URL: '$drive_new_url'. Must start with http://, https://, ws://, or wss://"
                return 1
                ;;
        esac
    else
        return 1
    fi
}

drive_omnigent_machine_key() {
    drive_os=$1
    drive_raw=
    if [ "$drive_os" = "linux" ] && [ -r /etc/machine-id ]; then
        drive_raw=$(tr -d '\r\n ' < /etc/machine-id)
    elif [ "$drive_os" = "darwin" ]; then
        drive_raw=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4}' || :)
    fi
    if [ -z "$drive_raw" ]; then
        drive_raw=$(uname -n 2>/dev/null || hostname 2>/dev/null || echo "host-unknown")
    fi
    drive_key=$(printf '%s' "$drive_raw" | sha256sum 2>/dev/null | awk '{print $1}' || :)
    if [ -z "$drive_key" ]; then
        drive_key=$(printf '%s' "$drive_raw" | shasum -a 256 2>/dev/null | awk '{print $1}' || :)
    fi
    if [ -z "$drive_key" ]; then
        drive_key="$drive_raw"
    fi
    printf '%s\n' "$drive_key"
}

drive_omnigent_host_identity() {
    drive_shared=$1
    drive_python=$2
    drive_os=$3
    drive_mkey=$(drive_omnigent_machine_key "$drive_os")
    drive_hname=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo "portable-host")
    drive_hdisplay="portable-${drive_hname}"

    drive_hosts_json="$drive_shared/credentials/omnigent-hosts.json"
    mkdir -p "$drive_shared/credentials"

    drive_id_script='
import json, uuid, sys, os
from pathlib import Path

hosts_file = Path(sys.argv[1])
machine_key = sys.argv[2]
display_name = sys.argv[3]

data = {}
if hosts_file.is_file():
    try:
        data = json.loads(hosts_file.read_text())
    except Exception:
        data = {}

if machine_key not in data or not isinstance(data.get(machine_key), dict) or "host_id" not in data[machine_key]:
    data[machine_key] = {
        "host_id": uuid.uuid4().hex,
        "host_name": display_name,
    }
    hosts_file.parent.mkdir(parents=True, exist_ok=True)
    tmp = hosts_file.with_name(hosts_file.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.replace(tmp, hosts_file)

entry = data[machine_key]
hid = entry["host_id"]
hname = entry["host_name"]
print(f"OMNIGENT_HOST_ID={hid}")
print(f"OMNIGENT_HOST_NAME={hname}")
'
    drive_id_output=$("$drive_python/bin/python3" -c "$drive_id_script" "$drive_hosts_json" "$drive_mkey" "$drive_hdisplay") || return 1
    eval "$drive_id_output"
    export OMNIGENT_HOST_ID OMNIGENT_HOST_NAME
}

drive_omnigent_environment() {
    drive_native=$1
    drive_target=$2
    drive_python="$drive_native/bin/$drive_target/python"
    drive_runtime="$drive_native/tools/omnigent-runtime"

    [ -x "$drive_python/bin/python3" ] || { drive_fail "Portable Python runtime not found at $drive_python. Provision this architecture first."; return 1; }

    export PYTHONHOME="$drive_python"
    export PYTHONNOUSERSITE=1
    export PYTHONPATH="$drive_runtime:$drive_runtime/site-packages${PYTHONPATH:+:$PYTHONPATH}"
    export PATH="$drive_python/bin:$drive_runtime/bin:$PATH"

    drive_terminfo="$drive_python/share/terminfo"
    export TERMINFO="$drive_terminfo"
    export TERMINFO_DIRS="$drive_terminfo:/usr/share/terminfo:/lib/terminfo:/etc/terminfo"

    if [ -f "$drive_runtime/certifi/cacert.pem" ]; then
        export SSL_CERT_FILE="$drive_runtime/certifi/cacert.pem"
        export REQUESTS_CA_BUNDLE="$drive_runtime/certifi/cacert.pem"
    fi
}
