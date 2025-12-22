# Building Sorbet Behind an Authenticated Proxy

## Problem

Bazel's Java-based HTTP downloader fails with "401 Unauthorized" or "Unable to tunnel through proxy" errors when behind an authenticated proxy. This is because Java's HTTP client doesn't properly handle proxy authentication during HTTPS CONNECT tunneling.

## Solution Overview

1. **Use curl for downloads** - curl correctly uses `$https_proxy` environment variables
2. **Pre-fetch dependencies** to a local distdir
3. **Install LLVM via apt** and use `--override_repository` (GitHub releases are often blocked)
4. **Download Bazel from GCS** instead of GitHub releases

## Quick Start

```bash
# Step 1: Install system LLVM (required - GitHub releases are blocked)
sudo apt-get update && sudo apt-get install -y clang-15 lld-15 llvm-15 llvm-15-dev

# Step 2: Download Bazel from GCS (not GitHub)
mkdir -p ~/.local/bin
curl -L -o ~/.local/bin/bazel "https://storage.googleapis.com/bazel/6.5.0/release/bazel-6.5.0-linux-x86_64"
chmod +x ~/.local/bin/bazel

# Step 3: Create distdir config
cat > .bazelrc.local << 'EOF'
build --distdir=/root/.cache/bazel-distdir
fetch --distdir=/root/.cache/bazel-distdir
query --distdir=/root/.cache/bazel-distdir
EOF

# Step 4: Pre-fetch dependencies
python3 prefetch_deps_v2.py

# Step 5: Setup local LLVM override
LLVM_LOCAL="/tmp/llvm_local"
mkdir -p "$LLVM_LOCAL"
cp -r /usr/lib/llvm-15/bin "$LLVM_LOCAL/"
cp -r /usr/lib/llvm-15/include "$LLVM_LOCAL/"
cp -r /usr/lib/llvm-15/lib "$LLVM_LOCAL/"
cp -r /usr/lib/llvm-15/share "$LLVM_LOCAL/"
echo 'workspace(name = "llvm_toolchain_15_0_7_llvm")' > "$LLVM_LOCAL/WORKSPACE"

# Step 6: Build with overrides
export LOCAL_BAZEL_OVERRIDE=~/.local/bin/bazel
./bazel build //main:sorbet --config=dbg --override_repository=llvm_toolchain_15_0_7_llvm=/tmp/llvm_local
```

## What Works Through the Proxy

| URL Pattern | Status | Alternative |
|-------------|--------|-------------|
| `github.com/*/archive/*` | ✅ Works | - |
| `github.com/*/releases/download/*` | ❌ Blocked (403) | Use mirrors or apt |
| `storage.googleapis.com/*` | ✅ Works | - |
| `mirror.bazel.build/*` | ⚠️ Partial | Some files available |

## Dependencies That Need Manual Handling

These GitHub releases are blocked and need alternatives:

```
# From third_party/externals.bzl (blocked):
- platforms-0.0.10.tar.gz (sha256: 218efe8ee736d26a...)
- rules_go-v0.43.0.zip (sha256: d6ab6b57e48c0952...)
- bazel-skylib-1.5.0.tar.gz (sha256: cd55a062e763b934...)
- bazel-lib-v2.7.0.tar.gz (sha256: 357dad9d212327c3...)
- rules_m4-v0.2.1.tar.xz (sha256: f59f75ac8a315d76...)
- libprism-src.tar.gz (sha256: a643517b910c510c...)

# From emsdk/deps.bzl (blocked):
- platforms-0.0.9.tar.gz (sha256: 5eda539c84126503...)
- bazel-skylib-1.1.1.tar.gz (sha256: c6966ec828da198c...)
- rules_nodejs-core-5.8.0.tar.gz (sha256: 08337d4fffc78f7f...)
- rules_nodejs-5.8.0.tar.gz (sha256: dcc55f810142b6cf...)

# LLVM toolchain (blocked):
- clang+llvm-15.0.7-x86_64-linux-gnu-ubuntu-20.04.tar.xz (sha256: 3393c29279aea207...)
```

## LLVM BUILD.bazel Template

If the Bazel cache doesn't have the BUILD file, create `/tmp/llvm_local/BUILD.bazel`:

```python
package(default_visibility = ["//visibility:public"])

exports_files(glob(["bin/*", "lib/*", "include/*"]))

filegroup(name = "clang", srcs = ["bin/clang", "bin/clang++", "bin/clang-cpp"])
filegroup(name = "ld", srcs = ["bin/ld.lld", "bin/ld64.lld"])
filegroup(name = "include", srcs = glob(["include/**/c++/**", "lib/clang/*/include/**"]))
filegroup(name = "bin", srcs = glob(["bin/**"]))
filegroup(name = "lib", srcs = glob(["lib/**/lib*.a", "lib/clang/*/lib/**/*.a", "lib/**/clang_rt.*.o"], exclude = ["lib/libLLVM*.a", "lib/libclang*.a", "lib/liblld*.a"]))
filegroup(name = "ar", srcs = ["bin/llvm-ar"])
filegroup(name = "as", srcs = ["bin/clang", "bin/llvm-as"])
filegroup(name = "nm", srcs = ["bin/llvm-nm"])
filegroup(name = "objcopy", srcs = ["bin/llvm-objcopy"])
filegroup(name = "objdump", srcs = ["bin/llvm-objdump"])
filegroup(name = "profdata", srcs = ["bin/llvm-profdata"])
filegroup(name = "dwp", srcs = ["bin/llvm-dwp"])
filegroup(name = "ranlib", srcs = ["bin/llvm-ranlib"])
filegroup(name = "readelf", srcs = ["bin/llvm-readelf"])
filegroup(name = "strip", srcs = ["bin/llvm-strip"])
filegroup(name = "symbolizer", srcs = ["bin/llvm-symbolizer"])
filegroup(name = "clang-tidy", srcs = ["bin/clang-tidy"])
```

## Troubleshooting

### "401 Unauthorized" from Bazel
This is the core proxy issue. Use the scripts provided - they use curl which handles proxy auth correctly.

### "Unable to tunnel through proxy"
Same issue. Bazel's Java HTTP client can't authenticate to the proxy.

### Missing dependencies after prefetch
Run `./fetch_all_deps.sh` which iteratively tries to build and downloads missing deps.

### LLVM download fails
Install via apt: `apt install clang-15 lld-15 llvm-15 llvm-15-dev` and use `--override_repository`.

### Build fails with "no such package '@build_bazel_rules_nodejs//'"
This is a transitive dep from emsdk. If you can't download it, you may need to get the files from another network and place them in `~/.cache/bazel-distdir/` with their SHA256 as filename.

## Files in This Repo

- `prefetch_deps_v2.py` - Downloads dependencies using curl to distdir
- `fetch_all_deps.sh` - Iterative build script with LLVM override
- `.bazelrc.local` - Local config for distdir (gitignored, create manually)

## Testing the Build

```bash
./bazel-bin/main/sorbet --version
./bazel-bin/main/sorbet -e "42 + 'hello'"  # Should show type error
```
