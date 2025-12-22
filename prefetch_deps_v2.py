#!/usr/bin/env python3
"""
Pre-fetch Sorbet dependencies using curl.
This bypasses Bazel's Java downloader which has proxy issues.
Files are named by URL basename for Bazel distdir compatibility.
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

DISTDIR = Path.home() / ".cache" / "bazel-distdir"

def extract_deps_from_bzl(filepath):
    """Extract http_archive URLs and SHA256s from a bzl file."""
    deps = []
    content = Path(filepath).read_text()

    archive_pattern = r'http_archive\s*\(\s*[^)]+\)'

    for match in re.finditer(archive_pattern, content, re.DOTALL):
        block = match.group(0)

        sha256_match = re.search(r'sha256\s*=\s*["\']([a-f0-9]{64})["\']', block)
        if not sha256_match:
            continue
        sha256 = sha256_match.group(1)

        urls = []
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
            deps.append({'urls': urls, 'sha256': sha256})

    return deps

def get_mirror_urls(url):
    """Generate mirror URLs for a given URL."""
    mirrors = [url]
    # Add Bazel mirror for GitHub releases
    if 'github.com' in url and '/releases/download/' in url:
        mirror = url.replace('https://github.com/', 'https://mirror.bazel.build/github.com/')
        mirrors.append(mirror)
    # Add Bazel mirror for other common URLs
    if 'mirror.bazel.build' not in url:
        mirror = 'https://mirror.bazel.build/' + url.replace('https://', '')
        mirrors.append(mirror)
    return mirrors

def download_dep(dep):
    """Download a dependency using curl."""
    sha256 = dep['sha256']

    for url in dep['urls']:
        basename = url.split('/')[-1]
        target_basename = DISTDIR / basename
        target_sha256 = DISTDIR / sha256  # Bazel also looks for files by SHA256

        # Check if we already have it (by basename or sha256)
        for target in [target_basename, target_sha256]:
            if target.exists():
                sha_result = subprocess.run(['sha256sum', str(target)], capture_output=True)
                actual_sha = sha_result.stdout.decode().split()[0]
                if actual_sha == sha256:
                    print(f"  Already have: {target.name}")
                    return True

        # Try all mirrors for this URL
        all_urls = get_mirror_urls(url)
        for try_url in all_urls:
            print(f"  Trying: {try_url}")
            tmp_file = target_basename.with_suffix('.tmp')

            try:
                result = subprocess.run(
                    ['curl', '-L', '-f', '--retry', '3', '--retry-delay', '5', '-o', str(tmp_file), try_url],
                    capture_output=True, timeout=300
                )

                if result.returncode != 0:
                    tmp_file.unlink(missing_ok=True)
                    continue

                sha_result = subprocess.run(['sha256sum', str(tmp_file)], capture_output=True)
                actual_sha = sha_result.stdout.decode().split()[0]

                if actual_sha == sha256:
                    # Save by both basename and SHA256 for maximum compatibility
                    tmp_file.rename(target_basename)
                    shutil.copy2(str(target_basename), str(target_sha256))
                    print(f"    OK: {basename}")
                    return True
                else:
                    print(f"    Checksum mismatch!")
                    tmp_file.unlink(missing_ok=True)
            except Exception as e:
                print(f"    Error: {e}")
                tmp_file.unlink(missing_ok=True)

    return False

def main():
    DISTDIR.mkdir(parents=True, exist_ok=True)

    print(f"Pre-fetching dependencies to {DISTDIR}")
    print(f"Using proxy: {os.environ.get('https_proxy', 'none')[:50]}...")

    all_deps = []

    bzl_files = ['third_party/externals.bzl']

    # Additional dependencies that are transitively required
    # These include EMSDK deps and other transitive dependencies
    workspace_deps = [
        {'urls': ['https://mirror.bazel.build/ftpmirror.gnu.org/gnu/make/make-4.4.tar.gz'],
         'sha256': '581f4d4e872da74b3941c874215898a7d35802f03732bdccee1d4a7979105d18'},
        # EMSDK transitive dependencies (from emsdk/deps.bzl)
        {'urls': ['https://github.com/bazelbuild/platforms/releases/download/0.0.9/platforms-0.0.9.tar.gz'],
         'sha256': '5eda539c841265031c2f82d8ae7a3a6490bd62176e0c038fc469eabf91f6149b'},
        {'urls': ['https://github.com/bazelbuild/bazel-skylib/releases/download/1.1.1/bazel-skylib-1.1.1.tar.gz'],
         'sha256': 'c6966ec828da198c5d9adbaa94c05e3a1c7f21bd012a0b29ba8ddbccb2c93b0d'},
        {'urls': ['https://github.com/bazelbuild/rules_nodejs/releases/download/5.8.0/rules_nodejs-core-5.8.0.tar.gz'],
         'sha256': '08337d4fffc78f7fe648a93be12ea2fc4e8eb9795a4e6aa48595b66b34555626'},
        {'urls': ['https://github.com/bazelbuild/rules_nodejs/releases/download/5.8.0/rules_nodejs-5.8.0.tar.gz'],
         'sha256': 'dcc55f810142b6cf46a44d0180a5a7fb923c04a5061e2e8d8eb05ccccc60864b'},
    ]

    for bzl_file in bzl_files:
        if Path(bzl_file).exists():
            print(f"Parsing {bzl_file}...")
            deps = extract_deps_from_bzl(bzl_file)
            print(f"  Found {len(deps)} dependencies")
            all_deps.extend(deps)

    all_deps.extend(workspace_deps)

    seen = set()
    unique_deps = []
    for dep in all_deps:
        if dep['sha256'] not in seen:
            seen.add(dep['sha256'])
            unique_deps.append(dep)

    print(f"\nTotal unique dependencies: {len(unique_deps)}\n")

    success = failed = 0
    for i, dep in enumerate(unique_deps, 1):
        print(f"[{i}/{len(unique_deps)}] {dep['sha256'][:16]}...")
        if download_dep(dep):
            success += 1
        else:
            failed += 1

    print(f"\nDone! Success: {success}, Failed: {failed}")
    return 0 if failed == 0 else 1

if __name__ == '__main__':
    sys.exit(main())
