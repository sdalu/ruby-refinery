require 'date'
require 'time'

module Refinery
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

        def truncate(mode = :second)
            reset      = [ 0, 1, 1, 0, 0, 0, gmt_offset ]
            parts      = [ :year, :month, :day, :hour, :minute, :second       ]
            breakpoint = parts.find_index(mode) || raise(ArgumentError)
            args       = parts[..breakpoint  ].map {|m| self.public_send(m) } +
                         reset[breakpoint+1..]
            Time.new(*args)
        end
    end
end

module TimeStepping
    refine Time do
        def step(limit, step = 1)
            limit = limit.to_time
            time  = self
            enum  = Enumerator.new do |y|
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
