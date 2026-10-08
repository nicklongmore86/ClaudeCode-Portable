#!/bin/sh
# Metadata only; no file contents or credentials are read.
set -eu
usage() { printf 'Usage: audit.sh snapshot DRIVE-OUTPUT | diff BEFORE AFTER\n' >&2; exit 2; }
[ "$#" -gt 0 ] || usage
case $1 in
    snapshot)
        [ "$#" -eq 2 ] || usage
        audit_output=$2
        mkdir -p "$(dirname -- "$audit_output")"
        # Store sort temporary files alongside the requested drive output.
        TMPDIR=$(CDPATH='' cd -- "$(dirname -- "$audit_output")" && pwd -P)
        export TMPDIR
        {
            for audit_path in "$HOME"/.[!.]* "$HOME"/..?* "$HOME/Library" /tmp /var/tmp; do
                [ -e "$audit_path" ] || continue
                if [ "$(uname -s)" = Darwin ]; then
                    find "$audit_path" -type f -exec stat -f '%N|%z|%m' {} + 2>/dev/null || :
                else
                    find "$audit_path" -type f -printf '%p|%s|%T@\n' 2>/dev/null || :
                fi
            done
        } | LC_ALL=C sort -u > "$audit_output"
        printf 'Snapshot: %s (unreadable paths skipped)\n' "$audit_output"
        ;;
    diff)
        [ "$#" -eq 3 ] || usage
        diff -u "$2" "$3" || { audit_status=$?; [ "$audit_status" -eq 1 ] || exit "$audit_status"; }
        ;;
    *) usage;;
esac
