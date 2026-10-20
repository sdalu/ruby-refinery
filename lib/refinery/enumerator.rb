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

    # Unwinds a source stopped partway (thrown, so that its ensures run
    # and not even a `rescue Exception` in the source holds it back)
    UNWIND = Object.new.freeze
    private_constant :UNWIND

    # One thread for the whole process serving every :hard walk that has
    # a deadline, as Timeout does: it sleeps until the earliest, then
    # raises that walk's own HardLimit into the walk's thread -- only if
    # the walk is armed, that is, inside its source.  Started on first
    # use; restarted when found dead, so after a fork.  A walk left
    # unfinished (an enumerator dropped between two #next) is disarmed,
    # so its entry is just dropped at its deadline.
    module Watchdog
        class Entry
            attr_reader   :deadline, :thread, :exc
            attr_accessor :armed, :fired

            def initialize(deadline)
                @deadline = deadline
                @thread   = Thread.current
                @exc      = HardLimit.new
                @armed    = false
                @fired    = false
            end
        end

        @mutex  = Mutex.new
        @cond   = ConditionVariable.new
        @queue  = []                # entries, earliest deadline first
        @thread = nil

        class << self
            # A walk of the current thread ending at +deadline+, not yet
            # armed: nothing can fire before the walk is ready to rescue
            def enter(deadline)
                entry = Entry.new(deadline)
                @mutex.synchronize do
                    start unless @thread&.alive?
                    at = @queue.bsearch_index { it.deadline > deadline } || @queue.size
                    @queue.insert(at, entry)
                    @cond.signal if at.zero?    # a new earliest deadline
                end
                entry
            end

            # Into the source: arm.  False once the deadline has passed.
            def arm(entry)
                @mutex.synchronize { entry.armed = !entry.fired }
            end

            # Hand-over: disarm.  Once this returns no HardLimit of this
            # walk can be raised any more; one raised just before is in
            # the thread's queue and is made to land here, still inside
            # the source, rather than later in the caller's code.
            # True once the deadline has passed.
            def disarm(entry)
                fired = @mutex.synchronize { entry.armed = false; entry.fired }
                Thread.handle_interrupt(HardLimit => :immediate) {} while Thread.pending_interrupt?(HardLimit)
                fired
            end

            # The walk is over.  Its own HardLimit, if still in flight, is
            # swallowed here; anything else found is raised after.
            def leave(entry)
                other = nil
                Thread.handle_interrupt(HardLimit => :never) do
                    @mutex.synchronize do
                        entry.armed = false
                        @queue.delete_if { it.equal?(entry) }
                    end
                    while Thread.pending_interrupt?(HardLimit)
                        begin
                            Thread.handle_interrupt(HardLimit => :immediate) {}
                        rescue HardLimit => e
                            other ||= e unless e.equal?(entry.exc)  # an enclosing walk's
                        rescue Exception => e                       # the caller's own
                            other = e unless other && !other.is_a?(HardLimit)
                        end
                    end
                end
                raise other if other
            end

            private

            def start
                # Threads inherit the interrupt mask of their creator
                Thread.handle_interrupt(Object => :immediate) do
                    @cond   = ConditionVariable.new       # after a fork: a fresh one
                    @queue.select! { it.thread.alive? }   # after a fork: the parent's threads are gone
                    @thread = Thread.new { run }
                    @thread.name = 'Refinery::EnumeratorThrottling::Watchdog'
                end
            end

            def run
                @mutex.synchronize do
                    loop do
                        entry = @queue.first
                        if entry.nil?
                            @cond.wait(@mutex)
                        elsif (left = entry.deadline - Time.now) > 0
                            @cond.wait(@mutex, left)
                        else
                            @queue.shift
                            entry.fired = true
                            begin
                                entry.thread.raise(entry.exc) if entry.armed && entry.thread.alive?
                            rescue ThreadError
                                nil                     # died meanwhile
                            end
                        end
                    end
                end
            end
        end
    end

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
            unless runtime.nil? || (runtime.is_a?(Numeric) && runtime.finite? && !runtime.negative?)
                raise ArgumentError, "expected runtime: seconds >= 0, got #{runtime.inspect}"
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

                # :hard.  The source runs here, on the iterating fiber,
                # as under :soft: it sees that fiber's fiber-locals and
                # owns its locks.  The Watchdog raises this walk's
                # HardLimit into this thread at the deadline, only while
                # the walk is armed: armed before entering the source,
                # disarmed at each hand-over before the item goes to the
                # caller, re-armed when the caller asks for the next
                # one.  So nothing fires into the caller's block, into
                # its code between two #next calls, or after it has left
                # (the ensure drains anything still in flight).  A
                # deadline passed while disarmed ends the walk at the
                # hand-over, by a throw the source cannot rescue, so its
                # ensures run.  Another walk's HardLimit (an enclosing
                # :hard walk) is passed on, not swallowed.
                entry = stop && Watchdog.enter(stop)
                catch(UNWIND) do
                    throw UNWIND if late.() || (entry && !Watchdog.arm(entry))
                    source.each do |*v|
                        throw UNWIND if entry && Watchdog.disarm(entry)
                        y.yield(*v)
                        throw UNWIND if late.() || (entry && !Watchdog.arm(entry))
                    end
                rescue HardLimit => e
                    raise unless entry && e.equal?(entry.exc)
                ensure
                    Watchdog.leave(entry) if entry
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
            # Checked now, not at the second item: nil slept forever, a
            # bad range or a negative pause raised once an item was out
            pause = ->(x) { x.is_a?(Numeric) && x.finite? && !x.negative? }
            ok    = if w.is_a?(Range)
                        pause.(w.begin) && pause.(w.end) &&
                            (w.exclude_end? ? w.begin < w.end : w.begin <= w.end)
                    else
                        pause.(w)
                    end
            unless ok
                raise ArgumentError, "expected seconds >= 0, or a non-empty Range of them, got #{w.inspect}"
            end
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
