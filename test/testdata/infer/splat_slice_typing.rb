# typed: true
# This test verifies that splat slice typing is precise for tuple literals.
# Prior to splatSlice, splat variables would get imprecise types from to_ary.
# With splatSlice, we can extract the exact tuple slice for the splat variable.

# Basic splat at end - extracts remaining elements as tuple
a, *b = [1, "hello", :world]
T.assert_type!(a, Integer)
T.reveal_type(b) # error: type: `[String, Symbol]`

# Splat at start - extracts leading elements as tuple
*c, d = [1, "hello", :world]
T.reveal_type(c) # error: type: `[Integer, String]`
T.assert_type!(d, Symbol)

# Splat in middle - extracts middle elements as tuple
e, *f, g = [1, 2, 3, 4, 5]
T.assert_type!(e, Integer)
T.reveal_type(f) # error: type: `[Integer, Integer, Integer]`
T.assert_type!(g, Integer)

# Mixed types with splat in middle
h, *i, j = [1, "two", :three, 4.0]
T.assert_type!(h, Integer)
T.reveal_type(i) # error: type: `[String, Symbol]`
T.assert_type!(j, Float)

# Empty splat when tuple exactly matches non-splat count
k, *l, m = [1, 2]
T.assert_type!(k, Integer)
T.reveal_type(l) # error: type: `[]`
T.assert_type!(m, Integer)

# Splat grabs all elements when no surrounding elements
*n = [1, 2, 3]
T.reveal_type(n) # error: type: `[Integer, Integer, Integer]`
