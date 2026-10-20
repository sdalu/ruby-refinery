module Refinery
module Stats
    # Over arrays of numbers.  Every method returns nil where the
    # statistic is undefined (an empty array, a sample of one).
    refine Array do
        # Arithmetic mean
        def mean
            return nil if empty?
            sum.fdiv(size)
        end

        def median = percentile(50)

        # The +p+-th percentile, 0 to 100, interpolated linearly between
        # the closest ranks (numpy's default, Excel's PERCENTILE.INC)
        def percentile(p)
            unless p.is_a?(Numeric) && (0..100).cover?(p)
                raise ArgumentError, "percentile must be within 0..100, got #{p.inspect}"
            end
            return nil if empty?
            s    = sort
            rank = (s.size - 1) * p / 100.0
            lo   = s[rank.floor]
            hi   = s[rank.ceil]
            return lo if lo == hi     # between two infinities: inf - inf is NaN
            lo + (hi - lo) * (rank - rank.floor)
        end

        # Population variance, or the sample one (divided by n - 1) with
        # +sample+
        def variance(sample: false)
            n = sample ? size - 1 : size
            return nil if n <= 0
            m = mean
            sum { (it - m) ** 2 }.fdiv(n)
        end

        def stddev(sample: false)
            variance(sample: sample)&.then { Math.sqrt(it) }
        end
    end
end
end
