#!/usr/bin/env python3
"""
Pre-fetch Sorbet dependencies using curl.
This bypasses Bazel's Java downloader which has proxy issues.
Files are named by URL basename for Bazel distdir compatibility.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

DISTDIR = Path.home() / ".cache" / "bazel-distdir"

def extract_deps_from_bzl(filepath):
    """Extract http_archive URLs and SHA256s from a bzl file."""
    deps = []
    content = Path(filepath).read_text()

    # Find all http_archive blocks
    archive_pattern = r'http_archive\s*\(\s*[^)]+\)'

    for match in re.finditer(archive_pattern, content, re.DOTALL):
        block = match.group(0)

        # Extract sha256
        sha256_match = re.search(r'sha256\s*=\s*["\']([a-f0-9]{64})["\']', block)
        if not sha256_match:
            continue
        sha256 = sha256_match.group(1)

        # Extract URL(s)
        urls = []

        # Try urls = [...] first
        urls_match = re.search(r'urls\s*=\s*\[([^\]]+)\]', block)
        if urls_match:
            urls_str = urls_match.group(1)
            for url_match in re.finditer(r'["\']([^"\']+)["\']', urls_str):
                urls.append(url_match.group(1))
        else:
            url_match = re.search(r'url\s*=\s*["\']([^"\']+)["\']', block)
            if url_match:
                urls.append(url_match.group(1))

        if urls and sha256:
            deps.append({
                'urls': urls,
                'sha256': sha256,
            })

    return deps

def download_dep(dep):
    """Download a dependency using curl."""
    sha256 = dep['sha256']

    for url in dep['urls']:
        # Get the basename from the URL
        basename = url.split('/')[-1]
        target = DISTDIR / basename

        if target.exists():
            # Verify checksum
            sha_result = subprocess.run(
                ['sha256sum', str(target)],
                capture_output=True
            )
            actual_sha = sha_result.stdout.decode().split()[0]
            if actual_sha == sha256:
                print(f"  Already have: {basename}")
                return True

        print(f"  Trying: {url}")
        tmp_file = target.with_suffix('.tmp')

        try:
            result = subprocess.run(
                ['curl', '-L', '-f', '--retry', '3', '--retry-delay', '5',
                 '-o', str(tmp_file), url],
                capture_output=True,
                timeout=300
            )

            if result.returncode != 0:
                print(f"    curl failed: {result.stderr.decode()[:200]}")
                continue

            # Verify checksum
            sha_result = subprocess.run(
                ['sha256sum', str(tmp_file)],
                capture_output=True
            )
            actual_sha = sha_result.stdout.decode().split()[0]

            if actual_sha == sha256:
                tmp_file.rename(target)
                print(f"    OK: {basename}")
                return True
            else:
                print(f"    Checksum mismatch!")
                print(f"    Expected: {sha256}")
                print(f"    Got: {actual_sha}")
                tmp_file.unlink(missing_ok=True)
        except subprocess.TimeoutExpired:
            print(f"    Timeout downloading {url}")
            tmp_file.unlink(missing_ok=True)
        except Exception as e:
            print(f"    Error: {e}")
            tmp_file.unlink(missing_ok=True)

    return False

def main():
    DISTDIR.mkdir(parents=True, exist_ok=True)

    print(f"Pre-fetching dependencies to {DISTDIR}")
    print(f"Using proxy: {os.environ.get('https_proxy', 'none')[:50]}...")
    print()

    # Collect all dependencies from build files
    all_deps = []

    bzl_files = [
        '/home/user/sorbet/third_party/externals.bzl',
    ]

    # Add WORKSPACE dependencies manually since they use different patterns
    workspace_deps = [
        {
            'urls': ['https://mirror.bazel.build/ftpmirror.gnu.org/gnu/make/make-4.4.tar.gz'],
            'sha256': '581f4d4e872da74b3941c874215898a7d35802f03732bdccee1d4a7979105d18'
        },
    ]

    for bzl_file in bzl_files:
        if Path(bzl_file).exists():
            print(f"Parsing {bzl_file}...")
            deps = extract_deps_from_bzl(bzl_file)
            print(f"  Found {len(deps)} dependencies")
            all_deps.extend(deps)

    all_deps.extend(workspace_deps)

    # Deduplicate by sha256
    seen = set()
    unique_deps = []
    for dep in all_deps:
        if dep['sha256'] not in seen:
            seen.add(dep['sha256'])
            unique_deps.append(dep)

    print(f"\nTotal unique dependencies: {len(unique_deps)}")
    print()

    # Download each dependency
    success = 0
    failed = 0

    for i, dep in enumerate(unique_deps, 1):
        print(f"[{i}/{len(unique_deps)}] {dep['sha256'][:16]}...")
        if download_dep(dep):
            success += 1
        else:
            failed += 1

    print()
    print(f"Done! Success: {success}, Failed: {failed}")

    return 0 if failed == 0 else 1

if __name__ == '__main__':
    sys.exit(main())
