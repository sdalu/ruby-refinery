require_relative 'helper'
require 'timeout'
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
    include Subprocess
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

    # DateTime has #minute and #second of its own: these precisions work
    # (from MadHouse, where a FIXME claimed they raised)
    def test_datetime_to_the_minute_and_second
        dt = DateTime.new(2020, 3, 4, 5, 6, 7)
        assert_equal DateTime.new(2020, 3, 4, 5, 6, 0), dt.truncate(:minute)
        assert_equal DateTime.new(2020, 3, 4, 5, 6, 7), dt.truncate(:second)
    end

    # A local time, to the minute: the hour-or-finer branch, which keeps
    # the offset and stays local (from MadHouse)
    def test_local_time_to_the_minute
        t = Time.new(2020, 3, 4, 5, 6, 7)
        m = t.truncate(:minute)
        assert_equal Time.new(2020, 3, 4, 5, 6, 0), m
        refute_nil m.zone, 'no longer local'
    end

    def test_time_keeps_its_offset
        t = Time.new(2026, 2, 18, 12, 34, 56.5, '+01:00')
        h = t.truncate(:hour)
        assert_equal Time.new(2026, 2, 18, 12, 0, 0, '+01:00'), h
        assert_equal 3600, h.utc_offset
        assert_equal Time.new(2026, 2, 18, 12, 34, 56, '+01:00'), t.truncate
    end

    # Regression: a local time was rebuilt with its own offset, wrong by
    # an hour once the truncation crossed a DST change.  In a child, for
    # its own TZ.
    def test_local_time_across_dst
        out, err, st = ruby_run(<<~RUBY)
            ENV['TZ'] = 'Europe/Paris'
            require 'refinery/datetime'
            using Refinery::TimeTruncate
            # summer to winter: the year and the month start in CET
            y = Time.local(2026, 7, 15, 12, 30).truncate(:year)
            raise y.inspect unless y == Time.local(2026, 1, 1) && y.utc_offset == 3600
            raise y.zone.inspect unless y.zone == 'CET'    # still local
            # the day DST starts: midnight is still CET
            d = Time.local(2026, 3, 29, 12).truncate(:day)
            raise d.inspect unless d == Time.new(2026, 3, 29, 0, 0, 0, '+01:00')
            # the hour repeated when DST ends: the second 02:00, not the first
            h = Time.new(2026, 10, 25, 2, 30, 0, '+01:00').localtime.truncate(:hour)
            raise h.inspect unless h == Time.new(2026, 10, 25, 2, 0, 0, '+01:00')
            raise h.zone.inspect unless h.zone == 'CET'
            # UTC stays UTC
            raise 'utc' unless Time.utc(2026, 7, 15, 12).truncate(:month).utc?
        RUBY
        assert st.success?, err + out
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

    # Regression: a Float step was added up, its binary error with it,
    # so 0.1 ten times went past T0 + 1 and the limit was left out
    def test_a_float_step_reaches_the_limit
        t0 = Time.at(0)
        e  = t0.step(t0 + 1, 0.1).to_a
        assert_equal 11, e.size
        assert_equal t0 + 1, e.last
        assert_equal t0 + Rational(3, 10), e[3]
        assert_equal 11, (t0 + 1).step(t0, -0.1).count
    end

    # Regression: a Float step was read to the nanosecond, so one below
    # half a nanosecond was 0 (the start repeated forever) and 1.5 ns
    # was bent into 2.5 ns.  Read relative to its size, it steps.
    def test_a_sub_nanosecond_step_steps
        t0 = Time.at(0)
        assert_equal 3, Timeout.timeout(2) { t0.step(t0 + 1e-9, 4e-10).count }
        assert_equal 3, Timeout.timeout(2) { (t0 + 1e-9).step(t0, -4e-10).count }
        assert_equal t0 + Rational(3, 2 * 10**9), t0.step(t0 + 1, 1.5e-9).first(2).last
        assert_equal 3, t0.step(t0 + 2e-9, 1e-9).count
    end

    # Regression: the cursor lived outside the enumerator, so a second
    # iteration resumed where the first stopped
    def test_reiterable
        e = T0.step(T1, 86400)
        assert_equal [ T0, T0 + 86400, T1 ], e.to_a
        assert_equal [ T0, T0 + 86400, T1 ], e.to_a
        e.first(2)
        assert_equal T0, e.to_a.first
    end
end
