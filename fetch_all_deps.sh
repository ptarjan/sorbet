#!/bin/bash
# Iteratively fetch all dependencies until build succeeds
#
# This script works around proxy issues with Bazel's Java downloader by:
# 1. Using a locally installed bazel binary (from GCS storage)
# 2. Using --override_repository for LLVM (system LLVM installed via apt)
# 3. Using --distdir for pre-fetched dependencies
#
# NOTE: Some GitHub release URLs may be blocked by enterprise proxies.
# See prefetch_deps_v2.py for the list of required dependencies.

set -e

# Use locally installed bazel binary (download via GCS storage if needed)
BAZEL_BIN="${HOME}/.local/bin/bazel"
if [ ! -f "$BAZEL_BIN" ]; then
    echo "Bazel not found at $BAZEL_BIN"
    echo "Installing from GCS storage..."
    mkdir -p "${HOME}/.local/bin"
    curl -L -o "$BAZEL_BIN" "https://storage.googleapis.com/bazel/6.5.0/release/bazel-6.5.0-linux-x86_64"
    chmod +x "$BAZEL_BIN"
fi
export LOCAL_BAZEL_OVERRIDE="$BAZEL_BIN"

# Setup LLVM override using system LLVM if available
LLVM_LOCAL="/tmp/llvm_local"
if [ -d "/usr/lib/llvm-15" ] && [ ! -d "$LLVM_LOCAL" ]; then
    echo "Setting up local LLVM from system installation..."
    mkdir -p "$LLVM_LOCAL"
    cp -r /usr/lib/llvm-15/bin "$LLVM_LOCAL/"
    cp -r /usr/lib/llvm-15/include "$LLVM_LOCAL/"
    cp -r /usr/lib/llvm-15/lib "$LLVM_LOCAL/"
    cp -r /usr/lib/llvm-15/share "$LLVM_LOCAL/"
    # Copy BUILD file from Bazel cache if available
    CACHE_DIR="${HOME}/.cache/bazel/_bazel_root"
    BUILD_FILE=$(find "$CACHE_DIR" -name "BUILD.bazel" -path "*/llvm_toolchain_15_0_7_llvm/*" 2>/dev/null | head -1)
    if [ -n "$BUILD_FILE" ]; then
        cp "$BUILD_FILE" "$LLVM_LOCAL/"
    fi
    echo 'workspace(name = "llvm_toolchain_15_0_7_llvm")' > "$LLVM_LOCAL/WORKSPACE"
fi

LLVM_OVERRIDE=""
if [ -d "$LLVM_LOCAL" ]; then
    LLVM_OVERRIDE="--override_repository=llvm_toolchain_15_0_7_llvm=$LLVM_LOCAL"
fi

DISTDIR="${HOME}/.cache/bazel-distdir"
mkdir -p "$DISTDIR"

MAX_ITERATIONS=20
iteration=0

while [ $iteration -lt $MAX_ITERATIONS ]; do
    iteration=$((iteration + 1))
    echo ""
    echo "=== Iteration $iteration ==="

    output=$(./bazel build //main:sorbet --config=dbg $LLVM_OVERRIDE 2>&1)

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

        # Try original URL first
        if curl -L -f --retry 3 --retry-delay 5 -o "$target.tmp" "$url" 2>/dev/null; then
            mv "$target.tmp" "$target"
            echo "  OK"
        else
            # Try GCS storage mirror for GitHub releases
            if [[ "$url" == *"github.com"*"/releases/download/"* ]]; then
                # Convert github.com/owner/repo/releases/download/version/file to GCS mirror
                mirror_url=$(echo "$url" | sed 's|https://github.com/|https://mirror.bazel.build/github.com/|')
                echo "  Trying mirror: $mirror_url"
                if curl -L -f --retry 3 --retry-delay 5 -o "$target.tmp" "$mirror_url" 2>/dev/null; then
                    mv "$target.tmp" "$target"
                    echo "  OK (from mirror)"
                else
                    echo "  FAILED (both original and mirror)"
                    rm -f "$target.tmp"
                fi
            else
                echo "  FAILED"
                rm -f "$target.tmp"
            fi
        fi
    done
done

echo "Max iterations reached"
exit 1
