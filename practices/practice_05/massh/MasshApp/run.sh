#!/bin/sh
# Debug run of the app straight from the build, logging to stderr.
set -eu
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
scratch=${BUILD:-$HOME/Library/Caches/massh}/MasshApp
swift build --scratch-path "$scratch"
exec "$(swift build --scratch-path "$scratch" --show-bin-path)/massh"
