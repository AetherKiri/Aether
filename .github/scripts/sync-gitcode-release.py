#!/usr/bin/env python3
"""
Sync GitHub Release to GitCode.
Creates a Release on GitCode (if not already existing) and uploads release assets.
"""

import argparse
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

GITCODE_API_BASE = "https://api.gitcode.com/api/v5"


def _sanitize_url(url: str) -> str:
    """Strip token-bearing query parameters for safe logging."""
    parsed = urllib.parse.urlsplit(url)
    if not parsed.query:
        return url
    qs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    filtered = [(k, v) for k, v in qs if k.lower() not in ("access_token", "token", "private-token")]
    clean_query = urllib.parse.urlencode(filtered)
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, clean_query, parsed.fragment))


def api_request(method: str, path: str, token: str, data: dict = None, headers: dict = None):
    url = f"{GITCODE_API_BASE}{path}"
    req_headers = {
        "User-Agent": "AetherKiri-Release-Sync",
        "private-token": token,
        "Authorization": f"token {token}",
    }
    if headers:
        req_headers.update(headers)

    body = None
    if method == "GET" or (method == "DELETE" and data is None):
        body = None
    elif data is not None and "multipart/form-data" not in req_headers.get("Content-Type", ""):
        req_headers["Content-Type"] = "application/json;charset=UTF-8"
        payload = dict(data)
        body = json.dumps(payload).encode("utf-8")
    else:
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
        safe_url = _sanitize_url(url)
        print(f"HTTPError {err.code} for {method} {safe_url}: {err_content}", file=sys.stderr)
        raise


def get_existing_release(owner: str, repo: str, tag: str, token: str):
    """Find release by tag name from GitCode releases list."""
    try:
        releases = api_request("GET", f"/repos/{owner}/{repo}/releases", token)
        if isinstance(releases, list):
            for r in releases:
                if r.get("tag_name") == tag:
                    return r
    except Exception as e:
        print(f"Failed to fetch existing releases: {e}", file=sys.stderr)
    return None


def is_tag_present(owner: str, repo: str, tag: str, token: str):
    """Check if tag exists in GitCode repository."""
    try:
        tags = api_request("GET", f"/repos/{owner}/{repo}/tags", token)
        if isinstance(tags, list):
            for t in tags:
                if isinstance(t, dict) and t.get("name") == tag:
                    return True
    except Exception as e:
        print(f"Warning: Failed to fetch tags from GitCode: {e}", file=sys.stderr)
    return False


def ensure_gitcode_tag(owner: str, repo: str, tag: str, token: str, username: str = "yorkyang2333"):
    """Ensure tag exists on GitCode; if missing, push the release tag directly to GitCode without exposing token in URL."""
    if is_tag_present(owner, repo, tag, token):
        print(f"Tag {tag} is already present on GitCode.")
        return True

    print(f"Tag {tag} not found on GitCode. Pushing tag {tag} to GitCode...")
    import subprocess
    import tempfile

    gitcode_url = f"https://gitcode.com/{owner}/{repo}.git"

    # Use a short-lived GIT_ASKPASS helper script so the token is never exposed in process args or URLs
    with tempfile.NamedTemporaryFile("w", delete=False) as askpass_file:
        askpass_file.write(
            "#!/bin/sh\n"
            'case "$1" in\n'
            f'  *Username*) echo "{username}" ;;\n'
            f'  *Password*) echo "{token}" ;;\n'
            f'  *) echo "{token}" ;;\n'
            "esac\n"
        )
        askpass_path = askpass_file.name

    os.chmod(askpass_path, 0o700)
    git_env = os.environ.copy()
    git_env["GIT_ASKPASS"] = askpass_path
    git_env["GIT_TERMINAL_PROMPT"] = "0"

    try:
        # Attempt 1: Try pushing tag directly from current repository if tag exists locally
        try:
            tag_check = subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}"], capture_output=True, text=True)
            if tag_check.returncode == 0:
                print(f"Found local tag {tag}. Pushing tag directly to GitCode...")
                push_res = subprocess.run(["git", "push", gitcode_url, f"refs/tags/{tag}:refs/tags/{tag}"], env=git_env, capture_output=True, text=True)
                if push_res.returncode == 0:
                    print(f"Successfully pushed tag {tag} to GitCode.")
                    return True
                else:
                    print(f"Notice: Direct git push tag failed: {push_res.stderr.strip()}", file=sys.stderr)
        except Exception as e:
            print(f"Notice: Local tag check failed: {e}", file=sys.stderr)

        # Attempt 2: Clone or fetch from GitHub to mirror the real commit/tag to GitCode
        with tempfile.TemporaryDirectory() as tmpdir:
            try:
                github_url = f"https://github.com/{owner}/{repo}.git"
                subprocess.run(["git", "clone", "--depth", "1", "--branch", tag, github_url, "."], cwd=tmpdir, check=True, capture_output=True)
                subprocess.run(["git", "push", gitcode_url, f"refs/tags/{tag}:refs/tags/{tag}"], env=git_env, cwd=tmpdir, check=True, capture_output=True)
                print(f"Successfully mirrored tag {tag} from GitHub to GitCode.")
                return True
            except Exception as e:
                print(f"Failed to push tag to GitCode: {e}", file=sys.stderr)
                return False
    finally:
        try:
            os.remove(askpass_path)
        except OSError:
            pass


def create_release(owner: str, repo: str, tag: str, token: str, name: str, body: str, prerelease: bool):
    """Create a new release on GitCode."""
    data = {
        "tag_name": tag,
        "name": name,
        "body": body or f"Release {tag}",
        "prerelease": prerelease,
    }
    return api_request("POST", f"/repos/{owner}/{repo}/releases", token, data=data)


def upload_asset(owner: str, repo: str, tag: str, token: str, file_path: str):
    """Upload asset file to GitCode release using GitCode OBS upload URL."""
    filename = os.path.basename(file_path)
    file_size = os.path.getsize(file_path)
    print(f"Requesting upload URL for {filename} ({file_size} bytes) on release {tag}...")

    # Step 1: Request OBS upload URL
    query_url = f"/repos/{owner}/{repo}/releases/{tag}/upload_url?file_name={urllib.parse.quote(filename)}"
    res = api_request("GET", query_url, token)
    if not isinstance(res, dict) or "url" not in res:
        raise RuntimeError(f"Unexpected upload_url response: {res}")

    obs_url = res["url"]
    custom_headers = res.get("headers", {})

    # Step 2: PUT binary stream to OBS storage
    print(f"Uploading {filename} to GitCode OBS storage...")
    put_headers = dict(custom_headers)
    put_headers["Content-Length"] = str(file_size)

    with open(file_path, "rb") as f:
        req_put = urllib.request.Request(obs_url, data=f, headers=put_headers, method="PUT")
        with urllib.request.urlopen(req_put) as resp_put:
            status = resp_put.status
            resp_text = resp_put.read().decode("utf-8", errors="replace")
            if status not in (200, 204):
                raise RuntimeError(f"OBS upload failed with HTTP {status}: {resp_text}")

    print(f"Successfully uploaded {filename} to GitCode.")
    return True


def main():
    parser = argparse.ArgumentParser(description="Sync release to GitCode")
    parser.add_argument("--owner", default="AetherKiri", help="GitCode repository owner")
    parser.add_argument("--repo", default="AetherKiri", help="GitCode repository name")
    parser.add_argument("--tag", required=True, help="Release tag name")
    parser.add_argument("--title", help="Release title")
    parser.add_argument("--body", default="", help="Release description / notes")
    parser.add_argument("--prerelease", action="store_true", help="Is pre-release")
    parser.add_argument("assets", nargs="*", help="File paths of assets to upload")

    args = parser.parse_args()

    token = os.environ.get("GITCODE_TOKEN", "").strip()
    if not token:
        print("Warning: GITCODE_TOKEN not set or empty. Skipping GitCode release sync.", file=sys.stderr)
        return 0

    tag = args.tag
    title = args.title or tag
    body = args.body

    # If body is not passed explicitly, attempt to mirror release notes from GitHub
    if not body:
        try:
            gh_url = f"https://api.github.com/repos/{args.owner}/{args.repo}/releases/tags/{tag}"
            gh_req = urllib.request.Request(gh_url, headers={"User-Agent": "AetherKiri-Release-Sync"})
            with urllib.request.urlopen(gh_req, timeout=10) as gh_resp:
                gh_data = json.loads(gh_resp.read().decode("utf-8"))
                body = gh_data.get("body", "")
                if not args.title:
                    title = gh_data.get("name") or tag
        except Exception as e:
            print(f"Notice: Could not fetch GitHub release notes automatically: {e}", file=sys.stderr)

    release = get_existing_release(args.owner, args.repo, tag, token)
    if release:
        print(f"Found existing release on GitCode for tag {tag}")
    else:
        # Ensure tag exists on GitCode release mirror
        ensure_gitcode_tag(args.owner, args.repo, tag, token)

        print(f"Creating release on GitCode for tag {tag}...")
        try:
            created = create_release(args.owner, args.repo, tag, token, title, body, args.prerelease)
            print(f"Created GitCode release for tag {tag}")
        except Exception as e:
            print(f"Error creating GitCode release: {e}", file=sys.stderr)
            return 1

    # Upload assets
    success_count = 0
    for asset_path in args.assets:
        if not os.path.isfile(asset_path):
            print(f"Skipping non-existent file: {asset_path}", file=sys.stderr)
            continue
        try:
            upload_asset(args.owner, args.repo, tag, token, asset_path)
            success_count += 1
        except Exception as e:
            print(f"Failed to upload asset {asset_path} to GitCode: {e}", file=sys.stderr)

    print(f"GitCode sync finished: {success_count}/{len(args.assets)} assets processed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
