#!/usr/bin/env python3
"""
Sync GitHub Release to GitCode.
Creates a Release on GitCode (if not already existing) and uploads release assets.
"""

import argparse
import json
import mimetypes
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

GITCODE_API_BASE = "https://api.gitcode.com/api/v5"

# Ensure Python unbuffered output so GitHub Actions runner prints logs immediately
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(line_buffering=True)
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(line_buffering=True)


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
    """Ensure tag exists on GitCode; if missing, push an empty bump version commit and tag to GitCode."""
    if is_tag_present(owner, repo, tag, token):
        print(f"Tag {tag} is already present on GitCode.")
        return True

    print(f"Tag {tag} not found on GitCode. Pushing bump version commit and tag {tag} to GitCode...")

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

    with tempfile.TemporaryDirectory() as tmpdir:
        try:
            print("Cloning shallow GitCode main branch...", flush=True)
            subprocess.run(
                ["git", "clone", "--depth", "1", "--branch", "main", gitcode_url, "."],
                cwd=tmpdir,
                env=git_env,
                check=True,
                capture_output=True,
                text=True,
                timeout=30,
            )
            subprocess.run(["git", "config", "user.name", username], cwd=tmpdir, check=True)
            subprocess.run(["git", "config", "user.email", f"{username}@users.noreply.gitcode.com"], cwd=tmpdir, check=True)
            print(f"Creating empty version bump commit 'chore: bump version to {tag}'...", flush=True)
            subprocess.run(
                ["git", "commit", "--allow-empty", "-m", f"chore: bump version to {tag}"],
                cwd=tmpdir,
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(["git", "tag", tag], cwd=tmpdir, check=True)

            max_retries = 3
            for attempt in range(1, max_retries + 1):
                try:
                    print(f"Pushing bump commit and tag {tag} to GitCode (attempt {attempt}/{max_retries})...", flush=True)
                    subprocess.run(
                        ["git", "push", "origin", "main", tag],
                        cwd=tmpdir,
                        env=git_env,
                        check=True,
                        capture_output=True,
                        text=True,
                        timeout=60,
                    )
                    print(f"Successfully pushed bump commit and tag {tag} to GitCode.", flush=True)
                    return True
                except subprocess.CalledProcessError as pe:
                    if attempt < max_retries:
                        err_detail = pe.stderr.strip() if pe.stderr else str(pe)
                        print(
                            f"Push attempt {attempt} failed ({err_detail}); pulling and rebasing...",
                            file=sys.stderr,
                            flush=True,
                        )
                        subprocess.run(
                            ["git", "pull", "--rebase", "origin", "main"],
                            cwd=tmpdir,
                            env=git_env,
                            check=True,
                            capture_output=True,
                            text=True,
                            timeout=30,
                        )
                    else:
                        raise
            return False
        except subprocess.TimeoutExpired as e:
            print(f"Error: Git operation timed out while pushing tag to GitCode: {e}", file=sys.stderr, flush=True)
            return False
        except subprocess.CalledProcessError as e:
            err_msg = e.stderr.strip() if e.stderr else str(e)
            print(f"Error: Failed to push tag to GitCode: {err_msg}", file=sys.stderr, flush=True)
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
    mb_size = file_size / (1024 * 1024)
    print(f"Requesting OBS upload URL for {filename} ({mb_size:.2f} MB)...", flush=True)

    # Step 1: Request OBS upload URL
    query_url = f"/repos/{owner}/{repo}/releases/{tag}/upload_url?file_name={urllib.parse.quote(filename)}"
    res = api_request("GET", query_url, token)
    if not isinstance(res, dict) or "url" not in res:
        raise RuntimeError(f"Unexpected upload_url response: {res}")

    obs_url = res["url"]
    custom_headers = res.get("headers", {})

    # Step 2: PUT binary stream to OBS storage using curl for high throughput and progress
    print(f"Uploading {filename} ({mb_size:.2f} MB) to GitCode OBS storage via curl...", flush=True)

    curl_cmd = [
        "curl",
        "-#",
        "--show-error",
        "--connect-timeout",
        "30",
        "--max-time",
        "900",
        "--retry",
        "3",
        "--retry-delay",
        "5",
        "-X",
        "PUT",
        "-T",
        file_path,
        "-H",
        f"Content-Length: {file_size}",
    ]

    for h_name, h_val in custom_headers.items():
        if h_name.lower() != "content-length":
            curl_cmd.extend(["-H", f"{h_name}: {h_val}"])

    curl_cmd.extend([
        "-o",
        "/dev/null",
        "-w",
        "%{http_code}",
        obs_url,
    ])

    # Let stderr flow to terminal live so the runner shows progress
    result = subprocess.run(curl_cmd, stdout=subprocess.PIPE, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"curl upload failed for {filename} with exit code {result.returncode}")

    http_status_str = result.stdout.strip().split("\n")[-1]
    try:
        http_status = int(http_status_str)
    except ValueError:
        raise RuntimeError(f"Invalid HTTP status returned by curl: {result.stdout.strip()}")

    if http_status not in (200, 204):
        err_msg = result.stderr.strip() if result.stderr else f"HTTP {http_status}"
        raise RuntimeError(f"OBS upload failed with HTTP {http_status}: {err_msg}")

    print(f"Successfully uploaded {filename} to GitCode.", flush=True)
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
        print("Warning: GITCODE_TOKEN not set or empty. Skipping GitCode release sync.", file=sys.stderr, flush=True)
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
            print(f"Notice: Could not fetch GitHub release notes automatically: {e}", file=sys.stderr, flush=True)

    release = get_existing_release(args.owner, args.repo, tag, token)
    if release:
        print(f"Found existing release on GitCode for tag {tag}", flush=True)
    else:
        # Ensure tag exists on GitCode release mirror
        if not ensure_gitcode_tag(args.owner, args.repo, tag, token):
            print(f"Error: Failed to ensure tag {tag} on GitCode. Aborting release creation.", file=sys.stderr, flush=True)
            return 1

        print(f"Creating release on GitCode for tag {tag}...", flush=True)
        try:
            created = create_release(args.owner, args.repo, tag, token, title, body, args.prerelease)
            print(f"Created GitCode release for tag {tag}", flush=True)
        except Exception as e:
            print(f"Error creating GitCode release: {e}", file=sys.stderr, flush=True)
            return 1

    # Upload assets
    failed_assets = []
    total = len(args.assets)
    for idx, asset_path in enumerate(args.assets, 1):
        if not os.path.isfile(asset_path):
            print(f"[{idx}/{total}] Skipping non-existent file: {asset_path}", file=sys.stderr, flush=True)
            failed_assets.append(asset_path)
            continue
        try:
            print(f"[{idx}/{total}] Uploading asset: {os.path.basename(asset_path)}...", flush=True)
            upload_asset(args.owner, args.repo, tag, token, asset_path)
        except Exception as e:
            print(f"[{idx}/{total}] Failed to upload asset {asset_path} to GitCode: {e}", file=sys.stderr, flush=True)
            failed_assets.append(asset_path)

    success_count = total - len(failed_assets)
    print(f"GitCode sync finished: {success_count}/{total} assets processed.", flush=True)
    if failed_assets:
        print(f"Error: {len(failed_assets)} asset(s) failed to upload.", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
