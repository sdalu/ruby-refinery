require_relative 'helper'
require 'refinery/hash'

class TestHashModify < Minitest::Test
    using Refinery::HashModify

    def test_modify_returns_a_new_hash
        h = { name: 'alice', age: 30 }
        assert_equal({ name: 'alice', age: 31 }, h.modify(:age) { it + 1 })
        assert_equal 30, h[:age]
    end

    def test_modify_in_place
        h = { age: 30 }
        assert_same h, h.modify!(:age) { it + 1 }
        assert_equal 31, h[:age]
    end

    def test_an_absent_key_is_left_alone_and_the_block_not_called
        h = { a: 1 }
        assert_same h, h.modify(:b)  { flunk 'block called' }
        assert_same h, h.modify!(:b) { flunk 'block called' }
        refute h.include?(:b)
    end
end

class TestHashToString < Minitest::Test
    using Refinery::HashToString

    def test_kvlist
        assert_equal 'a=1, b=2',  { a: 1, b: 2 }.to_str_kvlist
        assert_equal 'a: 1 b: 2', { a: 1, b: 2 }.to_str_kvlist(': ', ' ')
        assert_equal '',          {}.to_str_kvlist
    end
end

class TestHashDeflateKeys < Minitest::Test
    using Refinery::HashDeflateKeys

    def test_dotted_and_bracketed_indices
        h = { 'person.0.name' => 'alice', 'person[0].age' => 30 }
        assert_equal({ 'person' => [ { 'name' => 'alice', 'age' => 30 } ] },
                     h.deflate_keys)
    end

    def test_custom_separator
        assert_equal({ 'a' => { 'b' => 1 } }, { 'a/b' => 1 }.deflate_keys(sep: '/'))
    end

    def test_mapper_applies_to_hash_keys_not_indices
        h = { 'a.0.b' => 1 }
        assert_equal({ a: [ { b: 1 } ] }, h.deflate_keys(&:to_sym))
    end

    # Regression: an index made an array that large, whatever it was:
    # one short key could exhaust memory.  (Small sizes only: the old
    # code allocates whatever the index says.)
    def test_refuses_an_index_past_max_index
        assert_equal({ 'a' => [ nil, nil, 1 ] }, { 'a[2]' => 1 }.deflate_keys(max_index: 2))
        e = assert_raises(ArgumentError) { { 'a[3]' => 1 }.deflate_keys(max_index: 2) }
        assert_match(/max_index/, e.message)
        assert_raises(ArgumentError) { { 'a.10001' => 1 }.deflate_keys }
        assert_equal 10_001, { 'a.10000' => 1 }.deflate_keys['a'].size
    end

    # Regression: max_index capped each index, not the whole: every key
    # could still make an array max_index long, 1000 times its own size.
    # In all, the arrays may hold max_index plus one slot per key.
    def test_many_keys_under_max_index_cannot_add_up
        h = (0...20).to_h { [ "a.#{it}.1000", 1 ] }
        e = assert_raises(ArgumentError) { h.deflate_keys(max_index: 1000) }
        assert_match(/slots/, e.message)
        dense = (0...1000).to_h { [ "row[#{it}].x[0]", it ] }      # 2000 slots
        assert_equal 1000, dense.deflate_keys(max_index: 1000)['row'].size
    end

    # Regression: a leaf and a nested key on one path lost the leaf in
    # one order and raised NoMethodError in the other
    def test_a_leaf_and_a_nested_key_on_one_path_are_refused
        assert_raises(ArgumentError) { { 'a.b' => 1, 'a'   => 2 }.deflate_keys }
        assert_raises(ArgumentError) { { 'a'   => 2, 'a.b' => 1 }.deflate_keys }
        assert_raises(ArgumentError) { { 'a.0' => 1, 'a.x' => 2 }.deflate_keys }
    end

    # Regression: the block got integer keys too, so &:to_sym raised
    def test_mapper_is_not_handed_an_integer_key
        assert_equal({ 0 => 1, b: 2 }, { '0' => 1, 'b' => 2 }.deflate_keys(&:to_sym))
    end

    # Regression: sep went into a gsub replacement unescaped, so a
    # backslash in it read as a back-reference: a[3] landed at index 1
    def test_bracket_index_with_a_backslash_separator
        assert_equal({ 'a' => [ nil, nil, nil, 'x' ] }, { 'a[3]' => 'x' }.deflate_keys(sep: '\\'))
        assert_equal({ 'a' => [ nil, nil, nil, 'x' ] }, { 'a[3]' => 'x' }.deflate_keys(sep: '\\&'))
    end

    # Regression: in an array, a nil leaf read as an empty slot, so a
    # branch replaced it, where under a hash key the conflict raised
    def test_a_nil_leaf_in_an_array_conflicts_with_a_branch
        assert_raises(ArgumentError) { { 'a.0' => nil, 'a.0.b' => 1 }.deflate_keys }
        assert_raises(ArgumentError) { { 'a.0.b' => 1, 'a.0' => nil }.deflate_keys }
        assert_equal({ 'a' => [ nil, { 'b' => 1 } ] }, { 'a.1.b' => 1 }.deflate_keys)
    end

    # Regression: a falsy leaf did not end the walk and became {}
    def test_falsy_leaves_are_kept
        h = { 'a' => nil, 'b.c' => false, 'd[0]' => nil, 'e' => 1 }
        assert_equal({ 'a' => nil, 'b' => { 'c' => false }, 'd' => [ nil ],
                       'e' => 1 }, h.deflate_keys)
    end
end
