require 'date'
require 'time'

module Refinery
module DateOfMonth
    refine Date do
        def start_of_month
            Date.new(self.year, self.month)
        end
        def end_of_month
            Date.new(self.year, self.month).next_month.prev_day
        end
    end
end

module TimeTruncate
    refine Date do
        def truncate(mode = :day)
            case mode
            when :year   then Date.new(year)
            when :month  then Date.new(year, month)
            when :day    then Date.new(year, month, day)
            else raise ArgumentError
            end
        end
    end

    refine DateTime do
        def truncate(mode = :day)
            reset      = [    0,       1,    1,     0,       0,       0, zone ]
            parts      = [ :year, :month, :day, :hour, :minute, :second       ]
            breakpoint = parts.find_index(mode) || raise(ArgumentError)
            args       = parts[..breakpoint  ].map {|m| self.public_send(m) } +
                         reset[breakpoint+1..]

            DateTime.new(*args)
        end
    end

    refine Time do
        def minute = min
        def second = sec

        # A local time stays local.  To the day or coarser, it is rebuilt
        # from the local zone, whose offset may differ from its own across
        # a DST change; to the hour or finer, it keeps its own offset,
        # which tells apart the two passes of an hour repeated as DST ends.
        def truncate(mode = :second)
            reset      = [ 0, 1, 1, 0, 0, 0 ]
            parts      = [ :year, :month, :day, :hour, :minute, :second ]
            breakpoint = parts.find_index(mode) || raise(ArgumentError)
            args       = parts[..breakpoint  ].map {|m| self.public_send(m) } +
                         reset[breakpoint+1..]
            local      = zone.is_a?(String) && !utc?

            if    local && breakpoint <= 2 then Time.local(*args)
            elsif local                    then Time.new(*args, utc_offset).localtime
            elsif utc?                     then Time.utc(*args)
            else                                Time.new(*args, utc_offset)
            end
        end
    end
end

module TimeStepping
    refine Time do
        def step(limit, step = 1)
            limit = limit.to_time
            start = self
            enum  = Enumerator.new do |y|
                time = start            # afresh on every iteration
                if    step < 0
                    while (time <=> limit) >= 0 do
                        y << time
                        time += step
                    end
                elsif step > 0
                    while (time <=> limit) <= 0 do
                        y << time
                        time += step
                    end
                else
                    loop { y << time }
                end
            end

            if block_given?
            then enum.each {|v| yield(v) }
            else enum
            end
        end
    end
end
end
