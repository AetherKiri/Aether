#!/usr/bin/env bash
set -euo pipefail

: "${AETHER_INTERNAL_DEPLOY_KEY:?Missing AetherInternal CI deploy key}"
: "${AETHER_SOFTPAL_DEPLOY_KEY:?Missing AetherSoftPal CI deploy key}"
: "${AETHER_LEAFTTT_DEPLOY_KEY:?Missing AetherLeafTtt CI deploy key}"

key_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/aether-submodules.XXXXXX")"
trap 'rm -rf "$key_dir"' EXIT
chmod 700 "$key_dir"
# Secrets uploaded from Windows may contain CRLF or a UTF-8 BOM. OpenSSH
# requires the original LF-delimited key format, including its final newline.
write_deploy_key() {
    local key_name="$1" key_value="$2"
    printf '%s\n' "$key_value" | tr -d '\r' | sed $'1s/^\xEF\xBB\xBF//' > "$key_dir/$key_name"
    chmod 600 "$key_dir/$key_name"
    if ! ssh-keygen -y -P "" -f "$key_dir/$key_name" > /dev/null 2>&1; then
        echo "Invalid private deploy key: $key_name" >&2
        return 1
    fi
}
write_deploy_key internal "$AETHER_INTERNAL_DEPLOY_KEY"
write_deploy_key softpal "$AETHER_SOFTPAL_DEPLOY_KEY"
write_deploy_key leafttt "$AETHER_LEAFTTT_DEPLOY_KEY"

# GitHub associates each deploy key with one private repository. The existing
# key fetches the other runtimes; SoftPal and LeafTtt use their own read-only keys.
export GIT_SSH_COMMAND="ssh -i $key_dir/internal -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git submodule update --init --recursive --depth 1 \
    packages/AetherInternal \
    packages/AetherKrkr \
    packages/AetherMAGES \
    packages/AetherN2System \
    packages/AetherMinori \
    packages/cmvs-rs \
    packages/EntisGLS-SDL3 \
    packages/AetherSiglus \
    packages/OnscripterYuri \
    packages/psdfile \
    packages/ruffle \
    packages/xsystem4 \
    packages/xsystem35 \
    packages/system3 \
    packages/rfvp \
    packages/tjs2Decompiler

export GIT_SSH_COMMAND="ssh -i $key_dir/softpal -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git submodule update --init --depth 1 packages/AetherSoftPal

export GIT_SSH_COMMAND="ssh -i $key_dir/leafttt -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git submodule update --init --recursive --depth 1 packages/AetherLeafTtt
