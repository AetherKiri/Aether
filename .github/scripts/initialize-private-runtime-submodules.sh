#!/usr/bin/env bash
set -euo pipefail

: "${AETHER_INTERNAL_DEPLOY_KEY:?Missing AetherInternal CI deploy key}"
: "${AETHER_SOFTPAL_DEPLOY_KEY:?Missing AetherSoftPal CI deploy key}"
: "${AETHER_EXHIBIT_DEPLOY_KEY:?Missing AetherExHIBIT CI deploy key}"
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
write_deploy_key exhibit "$AETHER_EXHIBIT_DEPLOY_KEY"

# GitHub associates each deploy key with one private repository. The existing
# key fetches the remaining runtimes. Each additional private repo has its own key.
export GIT_SSH_COMMAND="ssh -i $key_dir/internal -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git submodule update --init --recursive --depth 1 \
    packages/AetherInternal \
    packages/AetherKrkr \
    packages/AetherMAGES \
    packages/AetherN2System \
    packages/AetherMinori \
    packages/AetherCMVS \
    packages/AetherEntisGLS \
    packages/AetherUnzip \
    packages/AetherSiglus \
    packages/AetherONScripterYuri \
    packages/psdfile \
    packages/ruffle \
    packages/AetherSystem4 \
    packages/AetherSystem35 \
    packages/AetherSystem3 \
    packages/rfvp \
    packages/tjs2Decompiler

export GIT_SSH_COMMAND="ssh -i $key_dir/softpal -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git submodule update --init --depth 1 packages/AetherSoftPal

export GIT_SSH_COMMAND="ssh -i $key_dir/leafttt -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git submodule update --init --recursive --depth 1 packages/AetherLeafTtt

export GIT_SSH_COMMAND="ssh -i $key_dir/exhibit -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git submodule update --init --recursive --depth 1 packages/AetherExHIBIT
test -f packages/AetherExHIBIT/integrations/aether/CMakeLists.txt
test "$(git -C packages/AetherExHIBIT rev-parse HEAD)" = "$(git rev-parse HEAD:packages/AetherExHIBIT)"
