#!/bin/bash
set +x
launch_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
# shellcheck source=launch/lib/drive.sh
. "$launch_dir/lib/drive.sh"
# shellcheck source=launch/lib/session.sh
. "$launch_dir/lib/session.sh"
drive_main linux "$0" "$@"
