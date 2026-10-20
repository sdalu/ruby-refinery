require_relative 'helper'
require 'refinery/enumerator'

class TestEnumeratorThrottling < Minitest::Test
    using Refinery::EnumeratorThrottling

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def timed
        t0 = clock
        r  = yield
        [ r, clock - t0 ]
    end

    def test_items_pass_through_as_each_yields_them
        h = { a: 1, b: 2 }
        assert_equal h.to_a, h.rate_limited(10).to_a
        assert_equal h.to_a, h.wait_inserted(0).to_a
        assert_equal h.to_a, h.time_limited(10).to_a
    end

    def test_re_iterable_with_pacing_afresh
        e = (1..3).rate_limited(2, per: 0.2)
        assert_equal [ 1, 2, 3 ], e.to_a
        _, dt = timed { assert_equal [ 1, 2 ], e.first(2) }
        assert_operator dt, :<, 0.1, 'second run waited on the first run\'s passes'
    end

    def test_rate_limited_paces
        _, dt = timed { (1..5).rate_limited(2, per: 0.1).to_a }
        assert_operator dt, :>=, 0.2      # passes 3 and 5 each wait a window
        assert_operator dt, :<,  0.5
    end

    def test_wait_inserted_pauses_only_between_items
        _, dt = timed { [ 1 ].wait_inserted(0.3).to_a }
        assert_operator dt, :<, 0.1
        _, dt = timed { [ 1, 2, 3 ].wait_inserted(0.05..0.06).to_a }
        assert_operator dt, :>=, 0.1
    end

    def test_soft_limit_never_interrupts_an_item
        done = []
        (1..5).time_limited(0.1) { sleep 0.15; done << it }
        assert_equal [ 1 ], done
    end

    def test_soft_limit_with_runtime_does_not_start_an_overrunning_item
        done = []
        (1..5).time_limited(0.1, runtime: 0.2) { done << it }
        assert_empty done
    end

    def test_hard_limit_interrupts_the_item
        done = []
        _, dt = timed { (1..5).time_limited(0.1, :hard) { sleep 1; done << it } }
        assert_empty done
        assert_operator dt, :<, 0.5
    end

    def test_hard_limit_does_not_swallow_the_callers_timeout
        assert_raises(Timeout::Error) do
            [ 1 ].time_limited(5, :hard) { Timeout.timeout(0.01) { sleep 1 } }
        end
    end

    def test_a_deadline_in_the_past_yields_nothing
        assert_empty (1..3).time_limited(Time.now - 1).to_a
    end

    def test_refusals_come_at_the_call_not_the_iteration
        assert_raises(ArgumentError) { [ 1 ].rate_limited(0) }
        assert_raises(ArgumentError) { [ 1 ].rate_limited(1.5) }
        assert_raises(ArgumentError) { [ 1 ].rate_limited(1, per: 0) }
        assert_raises(TypeError)     { [ 1 ].time_limited('soon') }
        assert_raises(ArgumentError) { [ 1 ].time_limited(1, :medium) }
    end
end
