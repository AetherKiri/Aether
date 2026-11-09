#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <Aether.xcodeproj> <output-directory>" >&2
    exit 2
fi

project_path="$1"
output_dir="$2"
bundle_id="${AETHER_IOS_BUNDLE_ID:-com.liuyu.aether.aether}"
team_id="${AETHER_APPLE_TEAM_ID:-3JL7FE9XQT}"
marketing_version="${AETHER_APPLE_VERSION:?AETHER_APPLE_VERSION is required}"
build_number="${AETHER_BUILD_NUMBER:?AETHER_BUILD_NUMBER is required}"
certificate_base64="${IOS_DISTRIBUTION_CERTIFICATE_BASE64:?IOS_DISTRIBUTION_CERTIFICATE_BASE64 is required}"
certificate_password="${IOS_DISTRIBUTION_CERTIFICATE_PASSWORD:?IOS_DISTRIBUTION_CERTIFICATE_PASSWORD is required}"
profile_base64="${IOS_PROVISIONING_PROFILE_BASE64:?IOS_PROVISIONING_PROFILE_BASE64 is required}"
import_profile_base64="${IOS_GAME_IMPORT_PROVISIONING_PROFILE_BASE64:?IOS_GAME_IMPORT_PROVISIONING_PROFILE_BASE64 is required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "$project_path" ]]; then
    echo "Xcode project not found: $project_path" >&2
    exit 1
fi

work_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/aether-ios-signing.XXXXXX")"
keychain_path="$work_dir/aether-signing.keychain-db"
certificate_path="$work_dir/distribution.p12"
profile_path="$work_dir/app-store.mobileprovision"
profile_plist="$work_dir/profile.plist"
archive_path="$work_dir/Aether.xcarchive"
export_dir="$work_dir/export"
export_options="$work_dir/ExportOptions.plist"
keychain_password="$(openssl rand -hex 24)"
installed_profiles=()
profile_backups=()
original_keychains=()

while IFS= read -r keychain; do
    keychain="${keychain//\"/}"
    keychain="${keychain#"${keychain%%[![:space:]]*}"}"
    if [[ -n "$keychain" ]]; then
        original_keychains+=("$keychain")
    fi
done < <(security list-keychains -d user)

cleanup() {
    if ((${#original_keychains[@]})); then
        security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
    fi
    for index in "${!installed_profiles[@]}"; do
        if [[ -f "${profile_backups[$index]}" ]]; then
            cp "${profile_backups[$index]}" "${installed_profiles[$index]}"
        else
            rm -f "${installed_profiles[$index]}"
        fi
    done
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
}
trap cleanup EXIT

printf '%s' "$certificate_base64" | /usr/bin/base64 -D > "$certificate_path"
printf '%s' "$profile_base64" | /usr/bin/base64 -D > "$profile_path"
printf '%s' "$import_profile_base64" | /usr/bin/base64 -D > "$work_dir/import.mobileprovision"

security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$certificate_path" \
    -k "$keychain_path" \
    -P "$certificate_password" \
    -A \
    -t cert \
    -f pkcs12
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$keychain_password" \
    "$keychain_path"
security list-keychains -d user -s "$keychain_path" "${original_keychains[@]}"
security find-identity -v -p codesigning "$keychain_path"

security cms -D -i "$profile_path" > "$profile_plist"
security cms -D -i "$work_dir/import.mobileprovision" > "$work_dir/import.plist"
python3 "$script_dir/configure-ios-signing.py" \
    --project "$project_path" --bundle-id "$bundle_id" --team-id "$team_id" \
    --app-profile "$profile_plist" --import-profile "$work_dir/import.plist" \
    --export-options "$export_options"

profile_dir="${HOME}/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profile_dir"
for name in app-store import; do
    plist="$profile_plist"
    if [[ "$name" == import ]]; then plist="$work_dir/import.plist"; fi
    uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$plist")"
    installed="$profile_dir/$uuid.mobileprovision"
    backup="$work_dir/$name.previous.mobileprovision"
    if [[ -f "$installed" ]]; then cp "$installed" "$backup"; fi
    installed_profiles+=("$installed")
    profile_backups+=("$backup")
    cp "$work_dir/$name.mobileprovision" "$installed"
done

rm -rf "$archive_path" "$export_dir"
xcodebuild archive \
    -project "$project_path" \
    -scheme Aether \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive_path" \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY='Apple Distribution' \
    MARKETING_VERSION="$marketing_version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    OTHER_CODE_SIGN_FLAGS="--keychain $keychain_path"

xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_options"

signed_ipa="$(find "$export_dir" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
if [[ -z "$signed_ipa" ]]; then
    echo "App Store IPA was not produced." >&2
    exit 1
fi

mkdir -p "$output_dir"
output_ipa="$output_dir/Aether-App-Store.ipa"
cp "$signed_ipa" "$output_ipa"

info_plist="$work_dir/Aether-Info.plist"
unzip -p "$output_ipa" Payload/Aether.app/Info.plist > "$info_plist"
actual_bundle_id="$(plutil -extract CFBundleIdentifier raw "$info_plist")"
actual_marketing_version="$(plutil -extract CFBundleShortVersionString raw "$info_plist")"
actual_build_number="$(plutil -extract CFBundleVersion raw "$info_plist")"
bluetooth_purpose="$(
    plutil -extract NSBluetoothAlwaysUsageDescription raw "$info_plist" \
        2>/dev/null || true
)"
status_bar_hidden="$(
    plutil -extract UIStatusBarHidden raw "$info_plist" \
        2>/dev/null || true
)"
uses_non_exempt_encryption="$(
    plutil -extract ITSAppUsesNonExemptEncryption raw "$info_plist" \
        2>/dev/null || true
)"
if [[ "$actual_bundle_id" != "$bundle_id" ||
      "$actual_marketing_version" != "$marketing_version" ||
      "$actual_build_number" != "$build_number" ]]; then
    echo "Signed IPA metadata does not match the requested release." >&2
    exit 1
fi
if [[ -z "$bluetooth_purpose" ]]; then
    echo "Signed IPA is missing NSBluetoothAlwaysUsageDescription." >&2
    exit 1
fi
if [[ "$status_bar_hidden" != "false" ]]; then
    echo "Signed IPA unexpectedly hides the native iOS status bar." >&2
    exit 1
fi
if [[ "$uses_non_exempt_encryption" != "false" ]]; then
    echo "Signed IPA is missing the exempt-encryption declaration." >&2
    exit 1
fi

verification_dir="$work_dir/verification"
mkdir -p "$verification_dir"
unzip -q "$output_ipa" -d "$verification_dir"
codesign --verify --deep --strict --verbose=2 \
    "$verification_dir/Payload/Aether.app"
import_extension="$verification_dir/Payload/Aether.app/PlugIns/AetherGameImport.appex"
if [[ ! -d "$import_extension" ]]; then
    echo "Signed IPA is missing the game-import extension." >&2
    exit 1
fi
actual_import_id="$(plutil -extract CFBundleIdentifier raw "$import_extension/Info.plist")"
if [[ "$actual_import_id" != "$bundle_id.GameImport" ]]; then
    echo "Signed import extension has an unexpected bundle ID." >&2
    exit 1
fi
codesign --verify --strict --verbose=2 "$import_extension"

echo "App Store IPA created: $output_ipa"
