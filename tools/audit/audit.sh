#!/bin/sh
# Metadata only; no file contents or credentials are read.
set -eu
usage() { printf 'Usage: audit.sh snapshot DRIVE-OUTPUT [ROOT ...] | diff BEFORE AFTER\n' >&2; exit 2; }
[ "$#" -gt 0 ] || usage
case $1 in
    snapshot)
        [ "$#" -ge 2 ] || usage
        audit_output=$2
        shift 2
        mkdir -p "$(dirname -- "$audit_output")"
        audit_output_dir=$(CDPATH='' cd -- "$(dirname -- "$audit_output")" && pwd -P)
        audit_output=$audit_output_dir/$(basename -- "$audit_output")
        umask 077
        audit_scratch=$(mktemp -d "$audit_output_dir/.audit-scratch.XXXXXX")
        trap 'rm -rf "$audit_scratch"' 0
        trap 'exit 130' INT
        trap 'exit 143' TERM HUP
        # Explicit -T plus all conventional temp variables keep sort spills on
        # the drive. The exit trap removes scratch on success and failure.
        TMPDIR=$audit_scratch TEMP=$audit_scratch TMP=$audit_scratch
        export TMPDIR TEMP TMP
        if [ "$#" -eq 0 ]; then
            set -- "$HOME"/.[!.]* "$HOME"/..?* "$HOME/Library" /tmp /var/tmp
        fi
        {
            for audit_path do
                [ -e "$audit_path" ] || continue
                # -H follows only command-line root symlinks (macOS /tmp and
                # /var/tmp), without traversing arbitrary links inside a tree.
                if [ "$(uname -s)" = Darwin ]; then
                    find -H "$audit_path" \( -path "$audit_scratch" -o -path "$audit_output" \) -prune -o -type f -exec stat -f '%N|%z|%m' {} + 2>/dev/null || :
                else
                    find -H "$audit_path" \( -path "$audit_scratch" -o -path "$audit_output" \) -prune -o -type f -printf '%p|%s|%T@\n' 2>/dev/null || :
                fi
            done
        } > "$audit_scratch/metadata"
        LC_ALL=C sort -T "$audit_scratch" -u "$audit_scratch/metadata" > "$audit_scratch/snapshot"
        mv -f "$audit_scratch/snapshot" "$audit_output"
        printf 'Snapshot: %s (unreadable paths skipped)\n' "$audit_output"
        ;;
    diff)
        [ "$#" -eq 3 ] || usage
        diff -u "$2" "$3" || { audit_status=$?; [ "$audit_status" -eq 1 ] || exit "$audit_status"; }
        ;;
    *) usage;;
esac
