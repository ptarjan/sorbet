#!/bin/bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR/..
source "test/logging.sh"

# Argument Parsing #############################################################

# Positional arguments
rbout=${1/--expected_output=/}

# TODO(trevor): Remove this once stderr is being checked
# shellcheck disable=SC2034
rberr=${2/--expected_err=/}
rbexit=${3/--expected_exit_code=/}
rbcode=$(< "$rbexit")
build_dir=${4/--build_dir=/}
ruby=${5/--ruby=/}
expect_fail=
case "${6/--expect_fail=/}" in
  True) expect_fail=1;;
  False) ;; #ok
  *) fatal "Expected --expect-fail=(True|False), got $6" ;;
esac
sorbet_exit=${7/--sorbet_exit=}
sorbet_out=${8/--sorbet_out=}
shift 8

# sources make up the remaining argumenets
rbmain=$1
rb=( "$@" )

# Environment Setup ############################################################

root="$PWD"

# Test stdout/stderr logs
stdout="$(mktemp)"
stderr="$(mktemp)"

# Test wrapper
runfile="$(mktemp)"

# Filtered versions of stderrs
stderr_filtered=$(mktemp)
rberr_filtered=$(mktemp)

cleanup() {
  rm -f "$stdout" "$stderr" "$runfile" "$stderr_filtered" "$rberr_filtered"
}
trap cleanup EXIT

# Main #########################################################################

echo ""
attn "Troubleshooting? Use these helpers interactively at the shell:"
info "├─ test/run_ruby.sh ${rb[0]}"
info "├─ test/run_sorbet.sh ${rb[0]}"
info "└─ test/run_compiled.sh ${rb[0]}"
info ""
attn "Or these to attach a debugger:"
info "├─ test/run_ruby.sh -d ${rb[0]}"
info "├─ test/run_sorbet.sh -d ${rb[0]}"
info "└─ test/run_compiled.sh -d ${rb[0]}"

echo ""
info "Testing ruby..."
if ! $ruby -e 'puts (require "set")' > /dev/null; then
  fatal "└─ Ruby is not functioning:  bazel-bin/$ruby"
else
  success "└─ path:        bazel-bin/$ruby"
fi

echo ""
info "Pre-computed output of running interpreted:"
info "├─ stdout:      bazel-out/k8-opt/bin/$rbout"
info "├─ stderr:      bazel-out/k8-opt/bin/$rberr"
info "└─ exit code:   $rbcode"

indent_and_nest() {
  sed -e 's/^/       │/'
}

something_failed() {
  if [ -n "$expect_fail" ]; then
    echo ""
    success "Disabled test failed as expected."
    info    "To make this failing test fail the build, move it out of the disabled folder."
    echo ""
    exit 0
  else
    echo ""
    error "Test failed."
    echo ""
    exit 1
  fi
}

echo    ""
info    "Compiled artifacts (.so/.bundle, .ll, .llo)..."
info    "├─ from:        ${build_dir}"
info    "├─ contents:"
find "$build_dir/" -type f | indent_and_nest
success "└─ done."

echo      ""
info      "Checking sorbet build dir..."
if [ "$(< "$sorbet_exit")" -ne 0 ]; then
  error  "├─ Sorbet failed when generating archive:"
  < "$sorbet_exit" indent_and_nest
  error  "└─ output is above."

  something_failed
fi
if [ -z "$(find "$build_dir/" -name '*.so' -o -name '*.bundle')" ]; then
  if ! grep -q '# typed:' "${rb[@]}"; then
    attn "├─ No '# typed: ...' sigil(s) in input files"
  fi

  if ! grep -q '# compiled:' "${rb[@]}"; then
    attn "├─ No '# compiled: ...' sigil(s) in input files"
  fi

  info   "├─ console output:"
  < "$sorbet_out" indent_and_nest

  error  '└─ no shared object produced. See above for potential reasons why.'

  something_failed
fi
success  "└─ done."

# NOTE: running the test could be split out into its own genrule, the test just
# needs to validate that the output matches.
echo ""
info "Running compiled version with preamble..."

# NOTE: using a temp file here, as that will cause ruby to not print the name of
# the main file in a stack trace.
echo "require './$rbmain'" > "$runfile"

set +e
# NOTE: the llvmir environment variable must have a leading `./`, otherwise the
# require will trigger path search.
force_compile=1 llvmir="$PWD/${build_dir}/" $ruby \
  --disable=gems \
  --disable=did_you_mean \
  -r "rubygems" \
  -r "${root}/gems/sorbet-runtime/lib/sorbet-runtime.rb" \
  -r "${root}/test/patch_require.rb" \
  "$runfile" \
  1> "$stdout" 2> "$stderr"
code=$?
set -e

info    "├─ stdout:      $stdout"
info    "├─ stderr:      $stderr"
success "└─ exit code:   $code"

shorten_bazel() {
  # Strip the full bazel cache path prefix to just leave bazel-out/...
  # This handles both the cache path format and the symlink format
  # Also strip bazel runfiles paths (.runfiles/com_stripe_ruby_typer/)
  sed -e "s+/[^ ]*_bazel_[^/]*/[^ ]*/execroot/com_stripe_ruby_typer/++" \
      -e "s+_bazel_$USER/[^ ]*com_stripe_ruby_typer/++" \
      -e "s+bazel-out/[^ ]*.runfiles/com_stripe_ruby_typer/++"
}

something_failed=

echo ""
info "Checking return codes match..."
if [[ "$code" != "$rbcode" ]]; then
  error "├─ return codes don't match."
  error "├─ Ruby:     ${rbcode}"
  error "└─ Compiled: ${code}"
  something_failed=1
else
  success "└─ codes match."
fi

echo ""
info "Checking stdouts match..."
if ! diff -au "$rbout" "$stdout" > stdout.diff; then
  attn  "├─ Diff (interpreted vs compiled)"
  < stdout.diff indent_and_nest
  info  "├─ stdout (interpreted)"
  < "$rbout" shorten_bazel | indent_and_nest
  info  "├─ stdout (compiled)"
  < "$stdout" shorten_bazel | indent_and_nest
  error "└─ stdouts don't match. See above."
  something_failed=1
else
  success "└─ stdouts match."
fi


echo ""
info "Checking stderrs match..."

filter_stderr() {
  sed -e '/^SorbetLLVM using compiled/d' | \
    shorten_bazel | \
    sed -e 's+/[^ ]*/tmp\.[[:alnum:]]*+/.../tmp.XXXXXXXXXX+'
}

if grep -q '^# skip_stderr_check$' "$rbmain"; then
  attn "└─ skipping stderr check."
else
  filter_stderr < "$rberr" > "$rberr_filtered"
  filter_stderr < "$stderr" > "$stderr_filtered"
  if ! diff -au "$rberr_filtered" "$stderr_filtered" > stderr.diff; then
    attn  "├─ Diff (interpreted vs compiled, filtered):"
    < stderr.diff indent_and_nest
    attn  "├─ Full compiled output (except bazel paths shortened):"
    < "$stderr" shorten_bazel | indent_and_nest
    error "└─ stderrs don't match. See above."
    something_failed=1
  else
    success "└─ stderrs match."
  fi
fi

if [ -n "$something_failed" ]; then
  something_failed
else
  if [ -z "$expect_fail" ]; then
    echo ""
    success "Test passed."
    info    "├─ stdout (interpreted):"
    < "$rbout" indent_and_nest
    info    "├─ stderr (interpreted):"
    < "$rberr" shorten_bazel | indent_and_nest
    success "└─ 🎉"

    echo ""
  else
    echo   ""
    error  "Disabled test did not fail."
    info   "This could mean that a recent change has made this test start passing."
    info   "If that's the case, great! Please move this test out of the disabled folder to catch future regressions."
    info   "├─ stdout (interpreted):"
    < "$rbout" indent_and_nest
    info   "├─ stderr (interpreted):"
    < "$rberr" shorten_bazel | indent_and_nest
    error "└─ ❌"

    echo ""
    exit 1
  fi
fi
