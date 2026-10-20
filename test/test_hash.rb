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

    # Regression: a falsy leaf did not end the walk and became {}
    def test_falsy_leaves_are_kept
        h = { 'a' => nil, 'b.c' => false, 'd[0]' => nil, 'e' => 1 }
        assert_equal({ 'a' => nil, 'b' => { 'c' => false }, 'd' => [ nil ],
                       'e' => 1 }, h.deflate_keys)
    end
end
