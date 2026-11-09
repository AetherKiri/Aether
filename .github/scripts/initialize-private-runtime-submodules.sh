#!/usr/bin/env bash
set -euo pipefail

: "${AETHER_INTERNAL_DEPLOY_KEY:?Missing AetherInternal CI deploy key}"
: "${AETHER_SOFTPAL_DEPLOY_KEY:?Missing AetherSoftPal CI deploy key}"
: "${AETHER_LEAFTTT_DEPLOY_KEY:?Missing AetherLeafTtt CI deploy key}"

key_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/aether-submodules.XXXXXX")"
trap 'rm -rf "$key_dir"' EXIT
chmod 700 "$key_dir"
printf '%s\n' "$AETHER_INTERNAL_DEPLOY_KEY" > "$key_dir/internal"
printf '%s\n' "$AETHER_SOFTPAL_DEPLOY_KEY" > "$key_dir/softpal"
printf '%s\n' "$AETHER_LEAFTTT_DEPLOY_KEY" > "$key_dir/leafttt"
chmod 600 "$key_dir/internal" "$key_dir/softpal" "$key_dir/leafttt"

# GitHub associates each deploy key with one private repository. The existing
# key fetches the other runtimes; SoftPal and LeafTtt use their own read-only keys.
export GIT_SSH_COMMAND="ssh -i $key_dir/internal -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git submodule update --init --recursive --depth 1 \
    packages/AetherInternal \
    packages/AetherKrkr \
    packages/AetherMAGES \
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
git submodule update --init --depth 1 packages/AetherLeafTtt
