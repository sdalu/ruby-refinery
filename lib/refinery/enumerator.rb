require 'timeout'

module Refinery
# Pacing an iteration whose steps cost something outside (one API call
# per item, say): a pause between items, a rate, a time budget.  Each
# method returns a new Enumerator, or iterates it at once with a block.
# The returned enumerator walks the receiver's own #each every time it
# is iterated, so it can be iterated again; its pacing starts afresh.
# Items are passed on exactly as #each yields them.
module EnumeratorThrottling
    # At most +limit+ passes per +interval+ seconds, over a sliding
    # window.
    class RateLimiter
        def initialize(limit, interval = 1)
            unless limit.is_a?(Integer) && limit.positive?
                raise ArgumentError, "limit must be a positive Integer, got #{limit.inspect}"
            end
            unless interval.is_a?(Numeric) && interval.positive?
                raise ArgumentError, "interval must be a positive number, got #{interval.inspect}"
            end
            @limit    = limit
            @interval = interval
            @passes   = []          # monotonic times of the last passes
            @mutex    = Mutex.new
        end

        # Wait until one more pass keeps within the rate, then count it
        def wait
            @mutex.synchronize do
                if @passes.size >= @limit
                    delta = clock - @passes.shift
                    sleep(@interval - delta) if delta < @interval
                end
                @passes << clock    # after the wait: when the pass happens
            end
        end

        private

        def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Raised by time_limited's :hard budget inside the source, and never
    # leaving time_limited.  Distinct from Timeout::Error, so that a
    # timeout of the caller's own is not swallowed; not a StandardError,
    # so that a source's plain `rescue => e` (a fetcher retrying) does
    # not swallow it.
    class HardLimit < Exception     # rubocop:disable Lint/InheritException
    end

    # Unwinds a source stopped partway, so that its ensures run; not a
    # StandardError, so that a plain rescue in the source lets it pass
    class Unwind < Exception        # rubocop:disable Lint/InheritException
    end
    private_constant :Unwind

    refine Enumerable do
        # Stop once +limit+ (seconds, or a deadline: a Time, or anything
        # with #to_time) is spent.  :soft checks before each item and never
        # interrupts one; with +runtime+, the expected seconds per item,
        # it does not start an item that would end past the limit.
        # :hard also interrupts the source while it produces an item,
        # and unwinds it.  The caller's code is never interrupted, its
        # block or, through #next, its code between two calls: the
        # iteration stops at the next item.  Both ways behave alike.
        def time_limited(limit, type = :soft, runtime: nil, &block)
            unless limit.is_a?(Numeric) || limit.is_a?(Time) ||
                   limit.respond_to?(:to_time)
                raise TypeError, "expected a Numeric, a Time or #to_time, got #{limit.class}"
            end
            unless %i[soft hard].include?(type)
                raise ArgumentError, "expected :hard or :soft, got #{type.inspect}"
            end
            if limit.is_a?(Float) && limit.nan?
                raise ArgumentError, "expected a number of seconds, got NaN"
            end
            source = self
            enum   = Enumerator.new do |y|
                start  = Time.now
                budget = case limit
                         when Numeric then limit
                         when Time    then limit - start
                         else              limit.to_time - start
                         end
                next if budget <= 0
                # An infinite budget is no limit (Time + Infinity raises)
                stop   = start + budget unless budget.infinite?
                late   = -> { stop && stop <= Time.now + (runtime || 0) }

                if type == :soft
                    source.each do |*v|
                        break if late.()
                        y.yield(*v)
                    end
                    next
                end

                # :hard.  The source runs in a fiber of its own, and the
                # timeout is armed only while it produces an item.  Armed
                # over the whole walk, it would fire wherever the thread
                # is: through #next, in the caller's code between two
                # calls, where nothing rescues it -- even after the caller
                # has left the enumerator.
                producer = Fiber.new do
                    source.each {|*v| Fiber.yield(v) }
                    nil
                rescue Unwind
                    nil
                end
                started = false
                begin
                    until late.()
                        left = stop && stop - Time.now  # nil: no deadline
                        break if left && left <= 0  # Timeout reads 0 as none
                        started = true
                        v = begin
                                Timeout.timeout(left, HardLimit) { producer.resume }
                            rescue HardLimit
                                break
                            end
                        break if v.nil?     # the source is done
                        y.yield(*v)
                    end
                ensure
                    producer.raise(Unwind) if started && producer.alive?
                end
            end
            block ? enum.each(&block) : enum
        end

        # At most +limit+ items per +per+ seconds
        def rate_limited(limit, per: 1, &block)
            RateLimiter.new(limit, per)     # validate now, not when iterated
            source = self
            enum   = Enumerator.new do |y|
                limiter = RateLimiter.new(limit, per)
                source.each do |*v|
                    limiter.wait
                    y.yield(*v)
                end
            end
            block ? enum.each(&block) : enum
        end

        # A pause of +w+ seconds between items (none before the first or
        # after the last); a Range gives a random pause within it.
        def wait_inserted(w = 0.0..1.0, &block)
            source = self
            enum   = Enumerator.new do |y|
                first = true
                source.each do |*v|
                    sleep(w.is_a?(Range) ? Random.rand(w) : w) unless first
                    first = false
                    y.yield(*v)
                end
            end
            block ? enum.each(&block) : enum
        end
    end
end
end
