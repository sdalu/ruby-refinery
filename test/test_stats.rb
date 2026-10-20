require_relative 'helper'
require 'refinery/stats'

class TestStats < Minitest::Test
    using Refinery::Stats

    A = [ 2, 4, 4, 4, 5, 5, 7, 9 ].freeze

    def test_central_tendency
        assert_equal 5.0, A.mean
        assert_equal 4.5, A.median
        assert_equal 4,   [ 9, 4, 1 ].median
    end

    # numpy.percentile(A, [0, 25, 90, 100]) => 2, 4, 7.6, 9
    def test_percentile_interpolates_as_numpy
        assert_equal 2,   A.percentile(0)
        assert_equal 4,   A.percentile(25)
        assert_in_delta 7.6, A.percentile(90)
        assert_equal 9,   A.percentile(100)
    end

    def test_percentile_does_not_depend_on_order
        assert_equal A.percentile(30), A.reverse.percentile(30)
    end

    def test_dispersion
        assert_equal 4.0, A.variance
        assert_equal 2.0, A.stddev
        assert_in_delta 32.0 / 7, A.variance(sample: true)
        assert_in_delta Math.sqrt(32.0 / 7), A.stddev(sample: true)
    end

    def test_undefined_statistics_are_nil
        assert_nil [].mean
        assert_nil [].median
        assert_nil [].percentile(50)
        assert_nil [].variance
        assert_nil [].stddev
        assert_nil [ 1 ].variance(sample: true)
        assert_nil [ 1 ].stddev(sample: true)
        assert_equal 0.0, [ 1 ].variance
    end

    # Regression: interpolating between two infinities gave NaN, where
    # numpy gives the infinity
    def test_infinite_values_do_not_make_nan
        inf = Float::INFINITY
        assert_equal inf,  [ inf ].median
        assert_equal inf,  [ 1.0, inf, inf ].median
        assert_equal(-inf, [ -inf, -inf, 0 ].percentile(25))
        assert_equal inf,  [ 1.0, inf ].median
    end

    def test_refuses_a_percentile_outside_0_to_100
        [ -1, 100.5, '50', nil ].each do |p|
            assert_raises(ArgumentError, p.inspect) { A.percentile(p) }
        end
        # Refused even where the answer would be nil
        assert_raises(ArgumentError) { [].percentile(101) }
    end
end
