#!/usr/bin/env bash
# Publish the Android release APK and its metadata to Cloudflare R2.
#
# Layout:
#   android/<version>/AetherKiri-<version>-android.apk
#   android/<version>/SHA256SUMS.txt
#   android/latest/AetherKiri-android-latest.apk   (stable tags only)
#   android/latest/version.txt                     (stable tags only)
#   latest.json                                    (stable tags only)
#
# Usage:
#   publish-r2-release.sh <apk-path>
#
# Required environment:
#   R2_ENDPOINT           S3 endpoint, e.g. https://<account>.r2.cloudflarestorage.com
#   R2_BUCKET             Bucket name
#   R2_ACCESS_KEY_ID      R2 access key ID
#   R2_SECRET_ACCESS_KEY  R2 secret access key
#   RELEASE_TAG           Git tag, e.g. 1.1.2 or v1.1.2
#
# Optional environment:
#   R2_PUBLIC_BASE_URL    Public base URL used for absolute links in latest.json
#   R2_PREFIX             Optional key prefix, e.g. staging
#   R2_RETAIN_VERSIONS    Number of versioned directories to keep (default: 5,
#                         0 disables pruning)
#   GITHUB_REPOSITORY     owner/repo, used for release_url
#   RELEASE_PUBLISHED_AT  ISO-8601 release timestamp
#   DRY_RUN=1             Print the upload plan without calling AWS
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <apk-path>" >&2
  exit 2
fi

apk_path="$1"
[[ -f "$apk_path" ]] || {
  echo "error: APK not found: $apk_path" >&2
  exit 1
}

dry_run="${DRY_RUN:-0}"
retain_versions="${R2_RETAIN_VERSIONS:-5}"
[[ "$retain_versions" =~ ^[0-9]+$ ]] || {
  echo "error: R2_RETAIN_VERSIONS must be a non-negative integer" >&2
  exit 1
}

for required in R2_ENDPOINT R2_BUCKET RELEASE_TAG; do
  value="${!required-}"
  [[ -n "$value" ]] || {
    echo "error: $required is required" >&2
    exit 1
  }
done

if [[ "$dry_run" != "1" ]]; then
  for required in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
    value="${!required-}"
    [[ -n "$value" ]] || {
      echo "error: $required is required" >&2
      exit 1
    }
  done
  command -v aws >/dev/null 2>&1 || {
    echo "error: the AWS CLI is required to publish to R2" >&2
    exit 1
  }
fi

raw_tag="${RELEASE_TAG#refs/tags/}"
version="${raw_tag#v}"
[[ -n "$version" ]] || {
  echo "error: RELEASE_TAG must contain a version" >&2
  exit 1
}
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] || {
  echo "error: unsupported release tag: $raw_tag" >&2
  exit 1
}
[[ "$version" != *..* ]] || {
  echo "error: unsupported release tag: $raw_tag" >&2
  exit 1
}

is_prerelease=0
[[ "$raw_tag" == *-* ]] && is_prerelease=1

prefix="${R2_PREFIX:-}"
prefix="${prefix#/}"
prefix="${prefix%/}"
[[ -n "$prefix" ]] && prefix="${prefix}/"

filename="AetherKiri-${version}-android.apk"
apk_mime="application/vnd.android.package-archive"
immutable_cache="public, max-age=31536000, immutable"
mutable_cache="public, max-age=300, must-revalidate"

if command -v sha256sum >/dev/null 2>&1; then
  sha256="$(sha256sum "$apk_path" | awk '{print $1}')"
else
  sha256="$(shasum -a 256 "$apk_path" | awk '{print $1}')"
fi
size="$(wc -c < "$apk_path" | tr -d '[:space:]')"

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
published_at="${RELEASE_PUBLISHED_AT:-}"
if [[ -z "$published_at" && "$dry_run" != "1" ]] &&
  command -v gh >/dev/null 2>&1 && [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
  published_at="$(
    gh release view "$raw_tag" \
      --repo "$GITHUB_REPOSITORY" \
      --json publishedAt \
      --jq '.publishedAt' 2>/dev/null || true
  )"
fi
published_at="${published_at:-$generated_at}"

release_url="${RELEASE_URL:-}"
if [[ -z "$release_url" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  release_url="https://github.com/${GITHUB_REPOSITORY}/releases/tag/${raw_tag}"
fi

tmp_root="${TMPDIR:-/tmp}"
tmp_root="${tmp_root%/}"
tmp_dir="$(mktemp -d "${tmp_root}/aether-r2.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

printf '%s  %s\n' "$sha256" "$filename" >"$tmp_dir/SHA256SUMS.txt"
printf '%s\n' "$version" >"$tmp_dir/version.txt"

if [[ "$dry_run" != "1" ]]; then
  export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
  export AWS_EC2_METADATA_DISABLED=true
  export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}"
  # R2 is S3-compatible but does not need the newer default SDK checksums.
  export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
  export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"
fi

aws_base=(aws --endpoint-url "$R2_ENDPOINT")
s3=("${aws_base[@]}" s3)
s3api=("${aws_base[@]}" s3api)

upload_object() {
  local source="$1"
  local key="$2"
  local content_type="$3"
  local cache_control="$4"
  local disposition="${5:-}"
  local metadata="${6:-}"
  local destination="s3://${R2_BUCKET}/${key}"

  if [[ "$dry_run" == "1" ]]; then
    printf '[dry-run] upload %s -> %s (content-type=%s, cache-control=%s)\n' \
      "$source" "$destination" "$content_type" "$cache_control"
    return 0
  fi

  local args=(
    cp "$source" "$destination"
    --only-show-errors
    --content-type "$content_type"
    --cache-control "$cache_control"
  )
  [[ -n "$disposition" ]] && args+=(--content-disposition "$disposition")
  [[ -n "$metadata" ]] && args+=(--metadata "$metadata")

  echo "Uploading ${destination}"
  "${s3[@]}" "${args[@]}"
}

verify_object() {
  local key="$1"
  local expected_size="$2"
  local expected_sha="${3:-}"

  if [[ "$dry_run" == "1" ]]; then
    printf '[dry-run] verify %s (size=%s, sha256=%s)\n' \
      "$key" "$expected_size" "$expected_sha"
    return 0
  fi

  local actual_size
  actual_size="$(
    "${s3api[@]}" head-object \
      --bucket "$R2_BUCKET" \
      --key "$key" \
      --query 'ContentLength' \
      --output text
  )"
  [[ "$actual_size" == "$expected_size" ]] || {
    echo "error: size mismatch for $key: $actual_size != $expected_size" >&2
    exit 1
  }

  if [[ -n "$expected_sha" ]]; then
    local actual_sha
    actual_sha="$(
      "${s3api[@]}" head-object \
        --bucket "$R2_BUCKET" \
        --key "$key" \
        --query 'Metadata.sha256' \
        --output text
    )"
    [[ "$actual_sha" == "$expected_sha" ]] || {
      echo "error: sha256 metadata mismatch for $key: $actual_sha != $expected_sha" >&2
      exit 1
    }
  fi
}

prune_old_versions() {
  local protected_version="$1"
  local retain="$2"
  local listing="$tmp_dir/version-prefixes.json"
  local deletions="$tmp_dir/prune.txt"

  "${s3api[@]}" list-objects-v2 \
    --bucket "$R2_BUCKET" \
    --prefix "${prefix}android/" \
    --delimiter "/" \
    --output json >"$listing"

  python3 - "$listing" "${prefix}android/" "$retain" "$protected_version" >"$deletions" <<'PY'
import json
import re
import sys

listing_path, key_prefix, retain_arg, protected = sys.argv[1:5]
retain = int(retain_arg)

with open(listing_path, encoding="utf-8") as source:
    data = json.load(source)

versions = []
for entry in data.get("CommonPrefixes", []):
    key = entry.get("Prefix", "")
    if not key.startswith(key_prefix) or not key.endswith("/"):
        continue
    name = key[len(key_prefix):-1]
    if not name or name == "latest" or not re.match(r"^[0-9][0-9A-Za-z._+-]*$", name):
        continue
    versions.append(name)


def semver_key(name):
    core, _, prerelease = name.partition("-")
    numbers = []
    for part in core.split("."):
        match = re.match(r"^(\d+)", part)
        numbers.append(int(match.group(1)) if match else 0)
    while len(numbers) < 3:
        numbers.append(0)
    if prerelease:
        identifiers = tuple(
            (0, int(part)) if part.isdigit() else (1, part)
            for part in prerelease.split(".")
        )
        return (tuple(numbers), 0, identifiers)
    return (tuple(numbers), 1, ())


versions.sort(key=semver_key)
cutoff = max(0, len(versions) - retain)
for index, name in enumerate(versions):
    if index < cutoff and name != protected:
        print(f"{key_prefix}{name}/")
PY

  if [[ -s "$deletions" ]]; then
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      echo "Retention: removing s3://${R2_BUCKET}/${key}"
      "${s3[@]}" rm "s3://${R2_BUCKET}/${key}" --recursive --only-show-errors
    done <"$deletions"
  else
    echo "Retention: nothing to prune (keeping up to ${retain} versions)."
  fi
}

version_is_newer() {
  local candidate="$1"
  local current="$2"
  [[ "$candidate" != "$current" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$candidate" "$current" | sort -V | tail -n 1)" == "$candidate" ]]
}

generate_latest_json() {
  local output="$1"
  VERSION="$version" \
    TAG="$raw_tag" \
    PREFIX="$prefix" \
    PUBLISHED_AT="$published_at" \
    GENERATED_AT="$generated_at" \
    RELEASE_URL="$release_url" \
    FILENAME="$filename" \
    SIZE="$size" \
    SHA256="$sha256" \
    PUBLIC_BASE_URL="${R2_PUBLIC_BASE_URL:-}" \
    python3 - "$output" <<'PY'
import json
import os
import sys

version = os.environ["VERSION"]
filename = os.environ["FILENAME"]
prefix = os.environ.get("PREFIX", "")
base = os.environ.get("PUBLIC_BASE_URL", "").rstrip("/")

android = {
    "file": f"{prefix}android/{version}/{filename}",
    "latest_file": f"{prefix}android/latest/AetherKiri-android-latest.apk",
    "size_bytes": int(os.environ["SIZE"]),
    "sha256": os.environ["SHA256"],
    "content_type": "application/vnd.android.package-archive",
}
if base:
    android["url"] = f"{base}/{android['file']}"
    android["latest_url"] = f"{base}/{android['latest_file']}"

doc = {
    "project": "AetherKiri",
    "channel": "stable",
    "version": version,
    "tag": os.environ["TAG"],
    "published_at": os.environ["PUBLISHED_AT"],
    "release_url": os.environ["RELEASE_URL"],
    "generated_at": os.environ["GENERATED_AT"],
    "android": android,
}

with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(doc, output, indent=2, ensure_ascii=False)
    output.write("\n")
PY
}

echo "Publishing AetherKiri ${version} (${size} bytes, sha256 ${sha256}) to s3://${R2_BUCKET}/${prefix}"

upload_object \
  "$apk_path" \
  "${prefix}android/${version}/${filename}" \
  "$apk_mime" \
  "$immutable_cache" \
  "attachment; filename=\"${filename}\"" \
  "sha256=${sha256}"
upload_object \
  "$tmp_dir/SHA256SUMS.txt" \
  "${prefix}android/${version}/SHA256SUMS.txt" \
  "text/plain; charset=utf-8" \
  "$immutable_cache"
verify_object "${prefix}android/${version}/${filename}" "$size" "$sha256"

current_version=""
if [[ "$dry_run" != "1" ]]; then
  # A failed listing must abort instead of being mistaken for a missing pointer;
  # otherwise a transient read error could move latest backwards.
  latest_listing="$("${s3[@]}" ls "s3://${R2_BUCKET}/${prefix}")"
  if grep -qE ' latest\.json$' <<<"$latest_listing"; then
    "${s3[@]}" cp \
      "s3://${R2_BUCKET}/${prefix}latest.json" \
      "$tmp_dir/current-latest.json" \
      --only-show-errors
    current_version="$(
      python3 - "$tmp_dir/current-latest.json" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        print(json.load(source).get("version", ""))
except Exception:
    print("")
PY
    )"
  fi
else
  echo "[dry-run] skip reading the current latest.json"
fi

should_publish_latest=1
if ((is_prerelease)); then
  should_publish_latest=0
  echo "Prerelease ${raw_tag}: publishing versioned artifacts only."
elif [[ -n "$current_version" && "$version" != "$current_version" ]] &&
  ! version_is_newer "$version" "$current_version"; then
  should_publish_latest=0
  echo "Current latest ${current_version} is newer than ${version}: latest pointers left unchanged."
fi

if ((should_publish_latest)); then
  generate_latest_json "$tmp_dir/latest.json"

  upload_object \
    "$apk_path" \
    "${prefix}android/latest/AetherKiri-android-latest.apk" \
    "$apk_mime" \
    "$mutable_cache" \
    'attachment; filename="AetherKiri-android-latest.apk"' \
    "sha256=${sha256}"
  verify_object "${prefix}android/latest/AetherKiri-android-latest.apk" "$size" "$sha256"
  upload_object \
    "$tmp_dir/version.txt" \
    "${prefix}android/latest/version.txt" \
    "text/plain; charset=utf-8" \
    "$mutable_cache"
  # Publish the pointer last so it never advertises an incomplete upload.
  upload_object \
    "$tmp_dir/latest.json" \
    "${prefix}latest.json" \
    "application/json; charset=utf-8" \
    "$mutable_cache"
fi

if ((retain_versions > 0)); then
  protected_version=""
  if ((should_publish_latest)); then
    protected_version="$version"
  else
    protected_version="$current_version"
  fi
  if [[ "$dry_run" == "1" ]]; then
    echo "[dry-run] retention: keep ${retain_versions} newest versions, protect ${protected_version:-none}"
  else
    prune_old_versions "$protected_version" "$retain_versions"
  fi
else
  echo "Retention: disabled (R2_RETAIN_VERSIONS=0)."
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Cloudflare R2 release"
    echo
    echo "- Version: \`${version}\`"
    echo "- APK: \`${prefix}android/${version}/${filename}\` (${size} bytes)"
    echo "- SHA256: \`${sha256}\`"
    if ((should_publish_latest)); then
      echo "- Latest: \`${prefix}android/latest/AetherKiri-android-latest.apk\`"
      echo "- Pointer: \`${prefix}latest.json\`"
    else
      echo "- Latest pointers: unchanged"
    fi
    if ((retain_versions > 0)); then
      echo "- Retention: keep ${retain_versions} newest versions"
    else
      echo "- Retention: disabled"
    fi
  } >>"$GITHUB_STEP_SUMMARY"
fi

echo "R2 publish complete for ${raw_tag}"
