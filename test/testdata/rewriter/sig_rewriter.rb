# typed: true
# This test verifies that signatures work correctly when rewritten to use
# Sorbet::Private::Static.sig(receiver) format.

class SigRewriterTest
  extend T::Sig

  # Standard sig - should be rewritten to Sorbet::Private::Static.sig(self) { ... }
  sig { returns(Integer) }
  def returns_integer
    42
  end

  # Sig with params
  sig { params(x: Integer, y: String).returns(String) }
  def with_params(x, y)
    "#{x}: #{y}"
  end

  # Sig with void
  sig { void }
  def void_method
  end

  # Sig with block
  sig { params(blk: T.proc.returns(Integer)).returns(Integer) }
  def with_block(&blk)
    blk.call
  end

  # Final sig
  sig(:final) { returns(Integer) }
  def final_method
    42
  end
end

# Test with T::Sig::WithoutRuntime - should be rewritten to
# Sorbet::Private::Static.sig(T::Sig::WithoutRuntime) { ... }
class WithoutRuntimeSigTest
  T::Sig::WithoutRuntime.sig { returns(Integer) }
  def returns_integer
    42
  end

  T::Sig::WithoutRuntime.sig { params(x: Integer).returns(String) }
  def with_param(x)
    x.to_s
  end
end

# Type checking should work correctly after sig rewriting
def test_type_checking
  test = SigRewriterTest.new
  result = test.returns_integer
  T.reveal_type(result) # error: Revealed type: `Integer`

  str = test.with_params(1, "hello")
  T.reveal_type(str) # error: Revealed type: `String`

  test2 = WithoutRuntimeSigTest.new
  result2 = test2.returns_integer
  T.reveal_type(result2) # error: Revealed type: `Integer`
end
