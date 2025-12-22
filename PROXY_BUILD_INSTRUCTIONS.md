# Building Sorbet Behind an Authenticated Proxy

## Problem

Bazel's Java-based HTTP downloader fails with "401 Unauthorized" or "Unable to tunnel through proxy" errors when behind an authenticated proxy. This is because Java's HTTP client doesn't properly handle proxy authentication during HTTPS CONNECT tunneling.

## Solution Overview

1. **Install system packages** - LLVM, libc++, bison, ragel, m4, Ruby
2. **Download Bazel from GCS** - GitHub releases are blocked
3. **Download blocked repos via codeload.github.com** - Works through proxy
4. **Use `--override_repository`** for all blocked dependencies
5. **Generate prism templates** using Ruby

## Complete Build Script

```bash
#!/bin/bash
set -e

# ============================================================================
# STEP 1: Install System Dependencies
# ============================================================================
sudo apt-get update
sudo apt-get install -y \
    clang-15 lld-15 llvm-15 llvm-15-dev \
    clang-format-15 \
    libc++-15-dev libc++abi-15-dev \
    ragel \
    ruby ruby-bundler

# Install rake-compiler for prism template generation
gem install rake-compiler

# ============================================================================
# STEP 2: Download Bazel from GCS (not GitHub)
# ============================================================================
mkdir -p ~/.local/bin
curl -L -o ~/.local/bin/bazel "https://storage.googleapis.com/bazel/6.5.0/release/bazel-6.5.0-linux-x86_64"
chmod +x ~/.local/bin/bazel
export LOCAL_BAZEL_OVERRIDE=~/.local/bin/bazel

# ============================================================================
# STEP 3: Setup Local LLVM
# ============================================================================
LLVM_LOCAL="/tmp/llvm_local"
mkdir -p "$LLVM_LOCAL"
cp -r /usr/lib/llvm-15/bin "$LLVM_LOCAL/"
cp -r /usr/lib/llvm-15/include "$LLVM_LOCAL/"
cp -r /usr/lib/llvm-15/lib "$LLVM_LOCAL/"
cp -r /usr/lib/llvm-15/share "$LLVM_LOCAL/"

# Add clang-format symlink
ln -sf /usr/bin/clang-format-15 "$LLVM_LOCAL/bin/clang-format"

# Copy libc++ libraries
cp /usr/lib/llvm-15/lib/libc++abi.a "$LLVM_LOCAL/lib/"
cp /usr/lib/x86_64-linux-gnu/libc++.a "$LLVM_LOCAL/lib/"
cp /usr/lib/llvm-15/lib/libc++abi.so* "$LLVM_LOCAL/lib/" 2>/dev/null || true
cp /usr/lib/x86_64-linux-gnu/libc++.so* "$LLVM_LOCAL/lib/" 2>/dev/null || true

echo 'workspace(name = "llvm_toolchain_15_0_7_llvm")' > "$LLVM_LOCAL/WORKSPACE"

# ============================================================================
# STEP 4: Download Blocked Repositories via codeload.github.com
# ============================================================================
REPOS_DIR="/tmp/bazel_repos"
mkdir -p "$REPOS_DIR"

download_repo() {
    local name=$1
    local org=$2
    local repo=$3
    local tag=$4
    local workspace_name=$5

    echo "Downloading $name..."
    mkdir -p "$REPOS_DIR/$name"
    curl -L -o "$REPOS_DIR/$name.tar.gz" "https://codeload.github.com/$org/$repo/tar.gz/refs/tags/$tag"
    tar -xzf "$REPOS_DIR/$name.tar.gz" -C "$REPOS_DIR/$name" --strip-components=1
    rm "$REPOS_DIR/$name.tar.gz"
    echo "workspace(name = \"$workspace_name\")" > "$REPOS_DIR/$name/WORKSPACE"
}

# Download all blocked repositories
download_repo "platforms" "bazelbuild" "platforms" "0.0.10" "platforms"
download_repo "bazel_skylib" "bazelbuild" "bazel-skylib" "1.5.0" "bazel_skylib"
download_repo "io_bazel_rules_go" "bazelbuild" "rules_go" "v0.43.0" "io_bazel_rules_go"
download_repo "aspect_bazel_lib" "aspect-build" "bazel-lib" "v2.7.0" "aspect_bazel_lib"
download_repo "rules_m4" "jmillikin" "rules_m4" "v0.2.3" "rules_m4"
download_repo "rules_java" "bazelbuild" "rules_java" "7.4.0" "rules_java"
download_repo "rules_cc" "bazelbuild" "rules_cc" "0.0.9" "rules_cc"
download_repo "rules_proto" "bazelbuild" "rules_proto" "5.3.0-21.7" "rules_proto"
download_repo "rules_pkg" "bazelbuild" "rules_pkg" "0.7.0" "rules_pkg"
download_repo "build_bazel_rules_nodejs" "aspect-build" "rules_nodejs" "core-5.8.2" "build_bazel_rules_nodejs"
download_repo "rules_nodejs" "aspect-build" "rules_nodejs" "5.8.2" "rules_nodejs"

# Download prism and generate templates
download_repo "prism" "ruby" "prism" "v1.6.0" "prism"
cp third_party/prism.BUILD "$REPOS_DIR/prism/BUILD.bazel"
cd "$REPOS_DIR/prism" && ruby -S rake templates
cd -

# ============================================================================
# STEP 5: Create Bison, M4, Ragel Wrappers (use system binaries)
# ============================================================================

# Bison wrapper
mkdir -p "$REPOS_DIR/bison_v3.3.2/bin"
mkdir -p "$REPOS_DIR/bison_v3.3.2/data"
cp -r /usr/share/bison/* "$REPOS_DIR/bison_v3.3.2/data/"
cat > "$REPOS_DIR/bison_v3.3.2/bin/bison_wrapper.sh" << 'WRAPPER'
#!/bin/bash
export BISON_PKGDATADIR="/usr/share/bison"
export M4="/usr/bin/m4"
exec /usr/bin/bison "$@"
WRAPPER
chmod +x "$REPOS_DIR/bison_v3.3.2/bin/bison_wrapper.sh"
echo 'workspace(name = "bison_v3.3.2")' > "$REPOS_DIR/bison_v3.3.2/WORKSPACE"
cat > "$REPOS_DIR/bison_v3.3.2/BUILD.bazel" << 'BUILD'
package(default_visibility = ["//visibility:public"])
filegroup(name = "bison_data", srcs = glob(["data/**/*"]))
BUILD
cat > "$REPOS_DIR/bison_v3.3.2/bin/BUILD.bazel" << 'BUILD'
package(default_visibility = ["//visibility:public"])
sh_binary(name = "bison", srcs = ["bison_wrapper.sh"], data = ["//:bison_data"])
BUILD

# M4 wrapper
mkdir -p "$REPOS_DIR/m4_v1.4.18/bin"
cat > "$REPOS_DIR/m4_v1.4.18/bin/m4_wrapper.sh" << 'WRAPPER'
#!/bin/bash
exec /usr/bin/m4 "$@"
WRAPPER
chmod +x "$REPOS_DIR/m4_v1.4.18/bin/m4_wrapper.sh"
echo 'workspace(name = "m4_v1.4.18")' > "$REPOS_DIR/m4_v1.4.18/WORKSPACE"
echo 'package(default_visibility = ["//visibility:public"])' > "$REPOS_DIR/m4_v1.4.18/BUILD.bazel"
cat > "$REPOS_DIR/m4_v1.4.18/bin/BUILD.bazel" << 'BUILD'
package(default_visibility = ["//visibility:public"])
sh_binary(name = "m4", srcs = ["m4_wrapper.sh"])
BUILD

# Ragel wrapper
mkdir -p "$REPOS_DIR/ragel_v6.10/bin"
cat > "$REPOS_DIR/ragel_v6.10/bin/ragel_wrapper.sh" << 'WRAPPER'
#!/bin/bash
exec /usr/bin/ragel "$@"
WRAPPER
chmod +x "$REPOS_DIR/ragel_v6.10/bin/ragel_wrapper.sh"
echo 'workspace(name = "ragel_v6.10")' > "$REPOS_DIR/ragel_v6.10/WORKSPACE"
echo 'package(default_visibility = ["//visibility:public"])' > "$REPOS_DIR/ragel_v6.10/BUILD.bazel"
cat > "$REPOS_DIR/ragel_v6.10/bin/BUILD.bazel" << 'BUILD'
package(default_visibility = ["//visibility:public"])
sh_binary(name = "ragel", srcs = ["ragel_wrapper.sh"])
BUILD

# ============================================================================
# STEP 6: Setup LLVM Toolchain Override
# ============================================================================
# First run a quick build to generate the toolchain files in cache
$LOCAL_BAZEL_OVERRIDE build @llvm_toolchain_15_0_7//:all --override_repository=llvm_toolchain_15_0_7_llvm=$LLVM_LOCAL 2>/dev/null || true

# Copy generated toolchain and fix paths
CACHE_DIR=$(find ~/.cache/bazel -type d -name "llvm_toolchain_15_0_7" 2>/dev/null | grep external | head -1)
if [ -n "$CACHE_DIR" ]; then
    mkdir -p "$REPOS_DIR/llvm_toolchain_15_0_7"
    cp "$CACHE_DIR/BUILD.bazel" "$REPOS_DIR/llvm_toolchain_15_0_7/"
    cp "$CACHE_DIR/WORKSPACE" "$REPOS_DIR/llvm_toolchain_15_0_7/"
    cp "$CACHE_DIR/toolchains.bzl" "$REPOS_DIR/llvm_toolchain_15_0_7/"
    mkdir -p "$REPOS_DIR/llvm_toolchain_15_0_7/bin"
    mkdir -p "$REPOS_DIR/llvm_toolchain_15_0_7/lib"
    cp "$CACHE_DIR/bin/cc_wrapper.sh" "$REPOS_DIR/llvm_toolchain_15_0_7/bin/"

    # Fix paths in cc_wrapper.sh and BUILD.bazel
    sed -i "s|$CACHE_DIR/../llvm_toolchain_15_0_7_llvm|$LLVM_LOCAL|g" "$REPOS_DIR/llvm_toolchain_15_0_7/bin/cc_wrapper.sh"
    sed -i "s|$CACHE_DIR/../llvm_toolchain_15_0_7_llvm|$LLVM_LOCAL|g" "$REPOS_DIR/llvm_toolchain_15_0_7/BUILD.bazel"

    # Add libc++ include path
    sed -i 's|"additional_include_dirs": \[\]|"additional_include_dirs": ["/usr/include/c++/v1"]|g' "$REPOS_DIR/llvm_toolchain_15_0_7/BUILD.bazel"

    # Create symlinks for tools
    ln -sf "$LLVM_LOCAL/bin/clang-format" "$REPOS_DIR/llvm_toolchain_15_0_7/bin/clang-format"
    ln -sf "$LLVM_LOCAL/bin/llvm-cov" "$REPOS_DIR/llvm_toolchain_15_0_7/bin/llvm-cov" 2>/dev/null || true
    ln -sf "$LLVM_LOCAL/bin/llvm-symbolizer" "$REPOS_DIR/llvm_toolchain_15_0_7/bin/llvm-symbolizer" 2>/dev/null || true
fi

# ============================================================================
# STEP 7: Create .bazelrc.local
# ============================================================================
cat > .bazelrc.local << 'EOF'
# Use pre-fetched dependencies to avoid proxy issues with Java downloader
build --distdir=/root/.cache/bazel-distdir
fetch --distdir=/root/.cache/bazel-distdir
query --distdir=/root/.cache/bazel-distdir

# Repository overrides for blocked GitHub releases
build --override_repository=llvm_toolchain_15_0_7_llvm=/tmp/llvm_local
build --override_repository=llvm_toolchain_15_0_7=/tmp/bazel_repos/llvm_toolchain_15_0_7
build --override_repository=build_bazel_rules_nodejs=/tmp/bazel_repos/build_bazel_rules_nodejs
build --override_repository=rules_nodejs=/tmp/bazel_repos/rules_nodejs
build --override_repository=platforms=/tmp/bazel_repos/platforms
build --override_repository=bazel_skylib=/tmp/bazel_repos/bazel_skylib
build --override_repository=io_bazel_rules_go=/tmp/bazel_repos/io_bazel_rules_go
build --override_repository=aspect_bazel_lib=/tmp/bazel_repos/aspect_bazel_lib
build --override_repository=rules_m4=/tmp/bazel_repos/rules_m4
build --override_repository=rules_java=/tmp/bazel_repos/rules_java
build --override_repository=rules_cc=/tmp/bazel_repos/rules_cc
build --override_repository=rules_proto=/tmp/bazel_repos/rules_proto
build --override_repository=rules_pkg=/tmp/bazel_repos/rules_pkg
build --override_repository=prism=/tmp/bazel_repos/prism
build --override_repository=bison_v3.3.2=/tmp/bazel_repos/bison_v3.3.2
build --override_repository=m4_v1.4.18=/tmp/bazel_repos/m4_v1.4.18
build --override_repository=ragel_v6.10=/tmp/bazel_repos/ragel_v6.10
EOF

# ============================================================================
# STEP 8: Run Pre-fetch Script (optional but recommended)
# ============================================================================
mkdir -p ~/.cache/bazel-distdir
python3 prefetch_deps_v2.py || true

# ============================================================================
# STEP 9: Build Sorbet
# ============================================================================
$LOCAL_BAZEL_OVERRIDE build //main:sorbet --config=dbg

# ============================================================================
# STEP 10: Test
# ============================================================================
./bazel-bin/main/sorbet --version
```

## What Works Through the Proxy

| URL Pattern | Status | Alternative |
|-------------|--------|-------------|
| `github.com/*/archive/*` | ✅ Works | - |
| `codeload.github.com/*` | ✅ Works | Use for downloads |
| `github.com/*/releases/download/*` | ❌ Blocked (403) | Use codeload or apt |
| `storage.googleapis.com/*` | ✅ Works | Use for Bazel |
| `ftp.gnu.org/*` | ❌ Blocked | Use apt packages |

## Key Insights

### GitHub Releases vs Source Archives
- **Releases** (`github.com/*/releases/download/*`) are blocked
- **Source archives** (`codeload.github.com/*`) work fine
- All Bazel dependencies can be downloaded via codeload

### System Package Substitutes
Instead of downloading from GitHub releases:
- **LLVM 15**: `apt install clang-15 lld-15 llvm-15 llvm-15-dev libc++-15-dev libc++abi-15-dev clang-format-15`
- **Bison**: `apt install bison` (system version 3.8.2 works)
- **M4**: Already installed on most systems
- **Ragel**: `apt install ragel`

### Prism Special Handling
The prism dependency expects pre-generated header files from the release tarball. Since we use the source archive, we must generate templates:
```bash
cd /tmp/bazel_repos/prism
gem install rake-compiler
ruby -S rake templates
```

## Troubleshooting

### "401 Unauthorized" from Bazel
Bazel's Java downloader can't handle authenticated proxies. Use curl-based downloads and `--override_repository`.

### "'fstream' file not found"
Missing libc++ headers. Install: `apt install libc++-15-dev libc++abi-15-dev`

### "unable to find library -l:libc++abi.a"
Copy libc++ libraries to LLVM local:
```bash
cp /usr/lib/llvm-15/lib/libc++abi.a /tmp/llvm_local/lib/
cp /usr/lib/x86_64-linux-gnu/libc++.a /tmp/llvm_local/lib/
```

### "m4 subprocess failed"
Update bison wrapper to set M4 environment variable:
```bash
export M4="/usr/bin/m4"
```

### "prism/diagnostic.h not found"
Generate prism templates: `cd /tmp/bazel_repos/prism && ruby -S rake templates`

## Files

- `.bazelrc.local` - Bazel configuration with all overrides
- `prefetch_deps_v2.py` - Downloads dependencies using curl
- `fetch_all_deps.sh` - Iterative build helper script
- `PROXY_BUILD_INSTRUCTIONS.md` - This file

## Testing the Build

```bash
./bazel-bin/main/sorbet --version
# Expected: Sorbet typechecker 0.5.0 (non-release) debug_symbols=true clean=0 debug_mode=true

./bazel-bin/main/sorbet --help | head -20
```
