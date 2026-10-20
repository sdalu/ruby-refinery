require_relative 'helper'
require 'date'
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
        assert_equal h.to_a, h.time_limited(10, :hard).to_a
        assert_equal [ [ 1, 2 ] ],
                     Enumerator.new { it.yield 1, 2 }.time_limited(10, :hard).to_a
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

    # As MadHouse's tado.rb uses it: an Array of Date, no block, .each,
    # the default pause.  The pauses are recorded, not slept: the
    # enumerator calls sleep on the receiver.
    def test_wait_inserted_default_pause_as_used_by_tado
        dates = [ Date.new(2026, 1, 1), Date.new(2026, 1, 2), Date.new(2026, 1, 3) ]
        log   = []
        dates.define_singleton_method(:sleep) { log << [ :pause, it ] }
        dates.wait_inserted.each { log << it }
        assert_equal dates.first, log.first, 'paused before the first item'
        assert_equal [ dates[0], :pause, dates[1], :pause, dates[2] ],
                     log.map { it.is_a?(Array) ? it.first : it }
        log.select { it.is_a?(Array) }.each do |_, s|
            assert_operator s, :>=, 0.0
            assert_operator s, :<=, 1.0
        end
    end

    # Every pair of items two apart, at least a window apart
    def test_rate_limited_keeps_the_rate_pair_by_pair
        start = clock
        at    = []
        (1..5).rate_limited(2, per: 0.2) { at << clock - start }
        [ [ 0, 2 ], [ 1, 3 ], [ 2, 4 ] ].each do |a, b|
            assert_operator at[b] - at[a], :>=, 0.19, "items #{a} and #{b}: #{at.inspect}"
        end
    end

    def test_every_enumerator_can_be_iterated_again
        [ (1..3).wait_inserted(0), (1..3).rate_limited(10),
          (1..3).time_limited(5), (1..3).time_limited(5, :hard) ].each do |e|
            assert_equal [ 1, 2, 3 ], e.to_a
            assert_equal [ 1, 2, 3 ], e.to_a
        end
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

    # A source whose third item hangs, noting when its ensure runs
    def hanging(log)
        Enumerator.new do |y|
            n = 0
            loop { sleep(n == 2 ? 5 : 0.01); y << (n += 1) }
        ensure
            log << :unwound
        end
    end

    def test_hard_limit_interrupts_the_source
        log  = []
        r, dt = timed { hanging(log).time_limited(0.3, :hard).to_a }
        assert_equal [ 1, 2 ], r
        assert_operator dt, :<, 1
        assert_equal [ :unwound ], log, 'source left paused, its ensure not run'
    end

    def test_hard_limit_interrupts_the_source_through_next
        log = []
        e   = hanging(log).time_limited(0.3, :hard)
        got = []
        loop { got << e.next }
        assert_equal [ 1, 2 ], got
        assert_equal [ :unwound ], log
    end

    # Regression: HardLimit was a StandardError, so a source retrying on
    # `rescue => e` swallowed it and ran past the limit
    def test_hard_limit_survives_a_source_rescuing_standard_error
        src = Enumerator.new do |y|
            tries = 0
            begin
                sleep 1
                y << :page
            rescue => e
                tries += 1
                retry if tries < 5
            end
        end
        r, dt = timed { src.time_limited(0.2, :hard).to_a }
        assert_empty r
        assert_operator dt, :<, 0.6
    end

    def test_hard_limit_unwinds_a_source_the_caller_breaks_out_of
        log = []
        src = Enumerator.new do |y|
            (1..).each { y << it }
        ensure
            log << :unwound
        end
        src.time_limited(5, :hard).each { break if it == 2 }
        assert_equal [ :unwound ], log
    end

    # Regression: through #next, HardLimit was raised into the caller's
    # code between two calls, where nothing rescued it
    # Nexts at about 0, 0.6 and 1.2 s: the 1.0 s limit falls in the
    # second sleep, 0.4 s from either next (0.1 s was too tight for a Pi)
    def test_hard_limit_through_next_ends_with_stop_iteration
        e   = (1..5).time_limited(1.0, :hard)
        got = []
        loop { got << e.next; sleep 0.6 }   # the limit falls in the sleep
        assert_equal [ 1, 2 ], got
    end

    # Regression: an enumerator left after two #next kept its timeout
    # armed, which fired later into unrelated code
    def test_hard_limit_never_fires_after_the_enumerator_is_left
        e = (1..5).time_limited(0.1, :hard)
        assert_equal [ 1, 2 ], [ e.next, e.next ]
        sleep 0.3                       # raised HardLimit here
    end

    # The caller's block, like its code between #next calls, is never
    # interrupted: the iteration stops at the next item
    def test_hard_limit_leaves_the_callers_block_alone
        done = []
        _, dt = timed { (1..5).time_limited(0.1, :hard) { sleep 0.2; done << it } }
        assert_equal [ 1 ], done
        assert_operator dt, :<, 0.8      # five items take 1 s; a slow host 0.44 s
    end

    def test_hard_limit_does_not_swallow_the_callers_timeout
        assert_raises(Timeout::Error) do
            [ 1 ].time_limited(5, :hard) { Timeout.timeout(0.01) { sleep 1 } }
        end
    end

    def test_a_deadline_in_the_past_yields_nothing
        assert_empty (1..3).time_limited(Time.now - 1).to_a
        assert_empty (1..3).time_limited(Time.now - 1, :hard).to_a
    end

    # Regression: an infinite budget raised FloatDomainError when
    # iterated; it is no limit
    def test_an_infinite_budget_is_no_limit
        assert_equal [ 1, 2 ], [ 1, 2 ].time_limited(Float::INFINITY).to_a
        assert_equal [ 1, 2 ], [ 1, 2 ].time_limited(Float::INFINITY, :hard).to_a
        assert_raises(ArgumentError) { [ 1 ].time_limited(Float::NAN) }
    end

    # Regression: :hard runs the source in a fiber of its own, where the
    # caller's fiber-locals were missing: a source reading them got nil
    def test_hard_source_sees_the_callers_fiber_locals
        Thread.current[:refinery_test_locale] = :fr
        src = Enumerator.new { |y| 3.times { y << Thread.current[:refinery_test_locale] } }
        assert_equal [ :fr ] * 3, src.time_limited(5, :hard).to_a
        assert_equal [ :fr ] * 3, src.time_limited(5).to_a
    ensure
        Thread.current[:refinery_test_locale] = nil
    end

    def test_refusals_come_at_the_call_not_the_iteration
        assert_raises(ArgumentError) { [ 1 ].rate_limited(0) }
        assert_raises(ArgumentError) { [ 1 ].rate_limited(1.5) }
        assert_raises(ArgumentError) { [ 1 ].rate_limited(1, per: 0) }
        assert_raises(TypeError)     { [ 1 ].time_limited('soon') }
        assert_raises(ArgumentError) { [ 1 ].time_limited(1, :medium) }
    end
end
