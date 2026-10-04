#!/usr/bin/env python3
"""
Sync GitHub Release to Gitee.
Creates a Release on Gitee (if not already existing) and uploads release assets.
"""

import argparse
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

GITEE_API_BASE = "https://gitee.com/api/v5"


def api_request(method: str, path: str, token: str, data: dict = None, headers: dict = None):
    url = f"{GITEE_API_BASE}{path}"
    req_headers = {
        "User-Agent": "AetherKiri-Release-Sync",
    }
    if headers:
        req_headers.update(headers)

    query_params = {"access_token": token}
    if method == "GET" or (method == "DELETE" and data is None):
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(query_params)
        body = None
    elif data is not None and "multipart/form-data" not in req_headers.get("Content-Type", ""):
        req_headers["Content-Type"] = "application/json;charset=UTF-8"
        payload = dict(data)
        payload["access_token"] = token
        body = json.dumps(payload).encode("utf-8")
    else:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(query_params)
        body = data

    req = urllib.request.Request(url, data=body, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            resp_body = resp.read().decode("utf-8")
            if resp_body:
                try:
                    return json.loads(resp_body)
                except json.JSONDecodeError:
                    return resp_body
            return None
    except urllib.error.HTTPError as err:
        err_content = err.read().decode("utf-8", errors="replace")
        print(f"HTTPError {err.code} for {method} {url}: {err_content}", file=sys.stderr)
        raise


def get_existing_release(owner: str, repo: str, tag: str, token: str):
    """Find release by tag name from Gitee releases list."""
    try:
        releases = api_request("GET", f"/repos/{owner}/{repo}/releases", token)
        if isinstance(releases, list):
            for r in releases:
                if r.get("tag_name") == tag:
                    return r
    except Exception as e:
        print(f"Failed to fetch existing releases: {e}", file=sys.stderr)
    return None


def create_release(owner: str, repo: str, tag: str, token: str, name: str, body: str, prerelease: bool):
    """Create a new release on Gitee."""
    data = {
        "tag_name": tag,
        "name": name,
        "body": body or f"Release {tag}",
        "prerelease": prerelease,
    }
    return api_request("POST", f"/repos/{owner}/{repo}/releases", token, data=data)


def upload_asset(owner: str, repo: str, release_id: int, token: str, file_path: str):
    """Upload asset file to Gitee release via multipart/form-data."""
    filename = os.path.basename(file_path)
    file_size = os.path.getsize(file_path)
    print(f"Uploading {filename} ({file_size} bytes) to release {release_id}...")

    boundary = f"----WebKitFormBoundary{uuid.uuid4().hex}"
    content_type = mimetypes.guess_type(file_path)[0] or "application/octet-stream"

    with open(file_path, "rb") as f:
        file_bytes = f.read()

    lines = []
    lines.append(f"--{boundary}".encode("utf-8"))
    lines.append(
        f'Content-Disposition: form-data; name="file"; filename="{filename}"'.encode("utf-8")
    )
    lines.append(f"Content-Type: {content_type}".encode("utf-8"))
    lines.append(b"")
    lines.append(file_bytes)
    lines.append(f"--{boundary}--".encode("utf-8"))
    lines.append(b"")

    body = b"\r\n".join(lines)
    headers = {
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "Content-Length": str(len(body)),
    }

    path = f"/repos/{owner}/{repo}/releases/{release_id}/attach_files"
    res = api_request("POST", path, token, data=body, headers=headers)
    print(f"Successfully uploaded {filename}.")
    return res


def main():
    parser = argparse.ArgumentParser(description="Sync release to Gitee")
    parser.add_argument("--owner", default="AetherKiri", help="Gitee repository owner")
    parser.add_argument("--repo", default="AetherKiri", help="Gitee repository name")
    parser.add_argument("--tag", required=True, help="Release tag name")
    parser.add_argument("--title", help="Release title")
    parser.add_argument("--body", default="", help="Release description / notes")
    parser.add_argument("--prerelease", action="store_true", help="Is pre-release")
    parser.add_argument("assets", nargs="*", help="File paths of assets to upload")

    args = parser.parse_args()

    token = os.environ.get("GITEE_TOKEN", "").strip()
    if not token:
        print("Warning: GITEE_TOKEN not set or empty. Skipping Gitee release sync.", file=sys.stderr)
        return 0

    tag = args.tag
    title = args.title or tag
    body = args.body

    release = get_existing_release(args.owner, args.repo, tag, token)
    if release:
        release_id = release["id"]
        print(f"Found existing release on Gitee: ID {release_id} (tag: {tag})")
    else:
        print(f"Creating release on Gitee for tag {tag}...")
        try:
            created = create_release(args.owner, args.repo, tag, token, title, body, args.prerelease)
            release_id = created["id"]
            print(f"Created Gitee release with ID {release_id}")
        except Exception as e:
            print(f"Error creating Gitee release: {e}", file=sys.stderr)
            return 1

    # Upload assets
    success_count = 0
    for asset_path in args.assets:
        if not os.path.isfile(asset_path):
            print(f"Skipping non-existent file: {asset_path}", file=sys.stderr)
            continue
        try:
            upload_asset(args.owner, args.repo, release_id, token, asset_path)
            success_count += 1
        except Exception as e:
            print(f"Failed to upload asset {asset_path} to Gitee: {e}", file=sys.stderr)

    print(f"Gitee sync finished: {success_count}/{len(args.assets)} assets processed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
