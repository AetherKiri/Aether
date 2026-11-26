#!/bin/sh
set -eu
cd "$(dirname "$0")"
build_dir=${TELEMETRY_BUILD_DIR:-build}
exec "${JAVA_HOME:+$JAVA_HOME/bin/}java" -cp "$build_dir/validator.jar:$build_dir/lib/*" aether.telemetry.ValidatorServer "$@"
