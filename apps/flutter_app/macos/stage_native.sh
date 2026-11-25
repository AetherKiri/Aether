#!/usr/bin/env bash
set -euo pipefail

frameworks_dir="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
resources_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$frameworks_dir" "$resources_dir"

for library in libaether_native_host.dylib libengine_api.dylib; do
    cp "$AETHER_NATIVE_LIB_DIR/$library" "$frameworks_dir/$library"
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]]; then
        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$frameworks_dir/$library"
    fi
done

cp "$AETHER_ROOT/apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf" "$resources_dir/"
