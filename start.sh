#!/bin/sh
set -eu
start_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
case $(uname -s) in
    Linux) exec bash "$start_dir/launch/linux.sh" "$@";;
    Darwin) exec bash "$start_dir/launch/macos.command" "$@";;
    *) printf 'Unsupported operating system\n' >&2; exit 1;;
esac
