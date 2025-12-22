# Building Sorbet Locally with Proxy Support

**Problem**: Bazel's Java-based HTTP downloader doesn't properly handle authenticated proxies (like the container proxy), failing with "401 Unauthorized" errors during the fetch phase.

**Solution**: Pre-fetch dependencies using `curl` (which handles proxy auth correctly), then configure Bazel to use a `distdir` containing those files.

## Step 1: Create the dependency prefetcher script

```bash
cat > prefetch_deps_v2.py << 'SCRIPT_EOF'
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

def download_dep(dep):
    """Download a dependency using curl."""
    sha256 = dep['sha256']

    for url in dep['urls']:
        basename = url.split('/')[-1]
        target = DISTDIR / basename

        if target.exists():
            sha_result = subprocess.run(['sha256sum', str(target)], capture_output=True)
            actual_sha = sha_result.stdout.decode().split()[0]
            if actual_sha == sha256:
                print(f"  Already have: {basename}")
                return True

        print(f"  Trying: {url}")
        tmp_file = target.with_suffix('.tmp')

        try:
            result = subprocess.run(
                ['curl', '-L', '-f', '--retry', '3', '--retry-delay', '5', '-o', str(tmp_file), url],
                capture_output=True, timeout=300
            )

            if result.returncode != 0:
                continue

            sha_result = subprocess.run(['sha256sum', str(tmp_file)], capture_output=True)
            actual_sha = sha_result.stdout.decode().split()[0]

            if actual_sha == sha256:
                tmp_file.rename(target)
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
    workspace_deps = [
        {'urls': ['https://mirror.bazel.build/ftpmirror.gnu.org/gnu/make/make-4.4.tar.gz'],
         'sha256': '581f4d4e872da74b3941c874215898a7d35802f03732bdccee1d4a7979105d18'}
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
SCRIPT_EOF
chmod +x prefetch_deps_v2.py
```

## Step 2: Create the iterative fetcher script

```bash
cat > fetch_all_deps.sh << 'SCRIPT_EOF'
#!/bin/bash
# Iteratively fetch all dependencies until build succeeds

DISTDIR="${HOME}/.cache/bazel-distdir"
mkdir -p "$DISTDIR"

MAX_ITERATIONS=20
iteration=0

while [ $iteration -lt $MAX_ITERATIONS ]; do
    iteration=$((iteration + 1))
    echo ""
    echo "=== Iteration $iteration ==="

    output=$(./bazel build //main:sorbet --config=dbg 2>&1)

    if echo "$output" | grep -q "Build completed successfully"; then
        echo "BUILD SUCCEEDED!"
        exit 0
    fi

    urls=$(echo "$output" | grep -oP "https://[^\s\]\)']+" | grep -v "^Unable" | sort -u)

    if [ -z "$urls" ]; then
        echo "No more URLs to download, but build still failing"
        echo "$output" | tail -20
        exit 1
    fi

    for url in $urls; do
        filename=$(basename "$url")
        target="$DISTDIR/$filename"

        if [ -f "$target" ]; then
            echo "Already have: $filename"
            continue
        fi

        echo "Downloading: $filename"
        if curl -L -f --retry 3 --retry-delay 5 -o "$target.tmp" "$url" 2>/dev/null; then
            mv "$target.tmp" "$target"
            echo "  OK"
        else
            echo "  FAILED"
            rm -f "$target.tmp"
        fi
    done
done

echo "Max iterations reached"
exit 1
SCRIPT_EOF
chmod +x fetch_all_deps.sh
```

## Step 3: Create Bazel configuration

```bash
cat > .bazelrc.local << 'EOF'
# Use pre-fetched dependencies to avoid proxy issues with Java downloader
build --distdir=$HOME/.cache/bazel-distdir
fetch --distdir=$HOME/.cache/bazel-distdir
query --distdir=$HOME/.cache/bazel-distdir
EOF
```

## Step 4: Run the build

```bash
# First, pre-fetch known dependencies from externals.bzl
python3 prefetch_deps_v2.py

# Then iteratively fetch any missing transitive dependencies and build
./fetch_all_deps.sh
```

## Alternative: Manual build after prefetch

If `fetch_all_deps.sh` gets stuck, you can manually iterate:

```bash
python3 prefetch_deps_v2.py
./bazel build //main:sorbet --config=dbg 2>&1 | grep "https://" | while read url; do
    curl -L -o ~/.cache/bazel-distdir/$(basename "$url") "$url"
done
# Repeat until build succeeds
```

## Testing the build

```bash
./bazel-bin/main/sorbet --version
./bazel-bin/main/sorbet -e "42 + 'hello'"  # Should show type error
```

## Key points

- **Proxy env vars work for curl**: `$https_proxy` and `$http_proxy` are correctly used by curl for downloading
- **Bazel's Java downloader fails**: It can't authenticate to the proxy during HTTPS CONNECT tunneling
- **distdir workaround**: Pre-fetch files with curl, then Bazel finds them locally without needing network access
- **Files are named by URL basename**: e.g., `rules_foreign_cc-d74623f0ad47f4e375de81baa454eb106715a416.zip`

## Build configurations

```bash
./bazel build //main:sorbet --config=dbg    # Debug build (recommended for development)
./bazel build //main:sorbet -c opt          # Optimized build
./bazel test //... --config=dbg             # Run all tests
```
