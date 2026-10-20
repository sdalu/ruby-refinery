require_relative 'helper'
require 'refinery/datetime'

class TestDateOfMonth < Minitest::Test
    using Refinery::DateOfMonth

    def test_start_and_end_of_month
        d = Date.new(2000, 10, 17)
        assert_equal Date.new(2000, 10,  1), d.start_of_month
        assert_equal Date.new(2000, 10, 31), d.end_of_month
    end

    def test_end_of_february_in_a_leap_year
        assert_equal Date.new(2024, 2, 29), Date.new(2024, 2, 3).end_of_month
        assert_equal Date.new(2023, 2, 28), Date.new(2023, 2, 3).end_of_month
    end
end

class TestTimeTruncate < Minitest::Test
    using Refinery::TimeTruncate

    def test_date
        d = Date.new(2026, 2, 18)
        assert_equal Date.new(2026, 1, 1),  d.truncate(:year)
        assert_equal Date.new(2026, 2, 1),  d.truncate(:month)
        assert_equal d,                     d.truncate
    end

    def test_datetime_keeps_its_zone
        dt = DateTime.new(2026, 2, 18, 12, 34, 56, '+01:00')
        assert_equal DateTime.new(2026, 2, 1, 0, 0, 0, '+01:00'), dt.truncate(:month)
        assert_equal DateTime.new(2026, 2, 18, 12, 0, 0, '+01:00'), dt.truncate(:hour)
    end

    def test_time_keeps_its_offset
        t = Time.new(2026, 2, 18, 12, 34, 56.5, '+01:00')
        h = t.truncate(:hour)
        assert_equal Time.new(2026, 2, 18, 12, 0, 0, '+01:00'), h
        assert_equal 3600, h.utc_offset
        assert_equal Time.new(2026, 2, 18, 12, 34, 56, '+01:00'), t.truncate
    end

    def test_refuses_an_unknown_precision
        assert_raises(ArgumentError) { Date.new(2026).truncate(:hour) }
        assert_raises(ArgumentError) { DateTime.now.truncate(:week) }
        assert_raises(ArgumentError) { Time.now.truncate(:week) }
    end
end

class TestTimeStepping < Minitest::Test
    using Refinery::TimeStepping

    T0 = Time.new(2026, 1, 1)
    T1 = Time.new(2026, 1, 3)

    def test_forward_includes_the_limit
        assert_equal [ T0, T0 + 86400, T1 ], T0.step(T1, 86400).to_a
    end

    def test_backward
        assert_equal [ T1, T1 - 86400, T0 ], T1.step(T0, -86400).to_a
    end

    def test_wrong_direction_is_empty
        assert_empty T1.step(T0, 86400).to_a
    end

    def test_zero_step_repeats_forever
        assert_equal [ T0 ] * 3, T0.step(T1, 0).first(3)
    end

    def test_with_a_block
        seen = []
        T0.step(T1, 86400) { seen << it }
        assert_equal 3, seen.size
    end
end
