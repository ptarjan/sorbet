# frozen_string_literal: true
# typed: true
# compiled: true
def foo
  bar
end

def bar
  path = Dir.getwd + '/'

  T.must(Thread.current.backtrace).map do |line|
    line
      .sub(path, '')
      # Strip bazel cache path prefix (e.g., /root/.cache/bazel/_bazel_root/.../execroot/com_stripe_ruby_typer/)
      .sub(%r{^/[^ ]*_bazel_[^/]+/[^/]+/execroot/com_stripe_ruby_typer/}, '')
      # Also strip the bazel cache path inside <internal:...> tags
      .sub(%r{(<internal:)/[^ ]*_bazel_[^/]+/[^/]+/execroot/com_stripe_ruby_typer/}, '\1')
      .sub(%r{.*test/patch_require.rb:.*:}, 'test/patch_require.rb:<censored>:')
      .sub(%r{^.*tmp\..*:}, '<censored>') # OSX
      .sub(%r{^/tmp.*:}, '<censored>')    # linux
  end
end

puts foo
