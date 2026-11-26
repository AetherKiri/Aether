#!/bin/sh
set -eu
cd "$(dirname "$0")"

build_dir=${TELEMETRY_BUILD_DIR:-build}
jackson_version=2.21.3
jackson_sha256=baf8b739e9d9b93bcdb33f25046bfdb8dbd74c97de2a8698539fbe0c7eeac0bb
jackson_jar="$build_dir/lib/jackson-core-$jackson_version.jar"
mkdir -p "$build_dir/classes" "$build_dir/lib"

if [ ! -f "$jackson_jar" ] || ! printf '%s  %s\n' "$jackson_sha256" "$jackson_jar" | sha256sum --check --status; then
    curl -fsSL --retry 2 --max-time 60 -o "$jackson_jar.tmp" \
      "https://repo.maven.apache.org/maven2/com/fasterxml/jackson/core/jackson-core/$jackson_version/jackson-core-$jackson_version.jar"
    printf '%s  %s\n' "$jackson_sha256" "$jackson_jar.tmp" | sha256sum --check --status
    # Copy the verified dependency to its runtime path.
    cp "$jackson_jar.tmp" "$jackson_jar"
fi

"${JAVA_HOME:+$JAVA_HOME/bin/}javac" --release 21 -cp "$jackson_jar" \
  -d "$build_dir/classes" src/aether/telemetry/*.java
"${JAVA_HOME:+$JAVA_HOME/bin/}jar" --create --file "$build_dir/validator.jar" \
  --main-class aether.telemetry.ValidatorServer -C "$build_dir/classes" .
