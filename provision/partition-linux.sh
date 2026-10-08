#!/bin/sh
set -eu
provision_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 "$provision_dir/partition-linux.py" "$@"
