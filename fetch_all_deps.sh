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

    # Run bazel and capture download failures
    output=$(./bazel build //main:sorbet --config=dbg 2>&1)

    # Check if we succeeded
    if echo "$output" | grep -q "Build completed successfully"; then
        echo "BUILD SUCCEEDED!"
        exit 0
    fi

    # Extract failed download URLs
    urls=$(echo "$output" | grep -oP "https://[^\s\]\)']+" | grep -v "^Unable" | sort -u)

    if [ -z "$urls" ]; then
        echo "No more URLs to download, but build still failing"
        echo "$output" | tail -20
        exit 1
    fi

    # Download each URL
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
