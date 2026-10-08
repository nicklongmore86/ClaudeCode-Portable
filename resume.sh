#!/bin/sh
exec sh "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)/start.sh" claude --resume "$@"
