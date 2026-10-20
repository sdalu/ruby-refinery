module Refinery
module HashModify
    refine Hash do
        def modify(key, &block)
            if self.include?(key)
            then merge(key => block.call(self[key]))
            else self
            end
        end

        def modify!(key, &block)
            if self.include?(key)
                self[key] = block.call(self[key])
            end
            self
        end
    end
end

module HashToString
    refine Hash do
        # { a: 1, b: 2 } => "a=1, b=2"
        def to_str_kvlist(assign = '=', sep = ', ')
            self.map {|k,v| "#{k}#{assign}#{v}" }.join(sep)
        end
    end
end

module HashDeflateKeys
  refine Hash do
    # An index above +max_index+ raises ArgumentError: an array is as
    # long as its largest index, so one key from outside (a form, a
    # query string) could otherwise exhaust memory.  And the arrays may
    # hold in all max_index slots, plus one per path segment of the keys
    # (dense input never needs more): else many keys under max_index
    # each could still add one long array.  A path that is both a leaf
    # and a branch ('a' and 'a.b') raises too.
    def deflate_keys(sep: '.', max_index: 10_000, &mapper)
      out    = {}
      branch = ->(c) { c.is_a?(Hash) || c.is_a?(Array) }
      budget = max_index     # array slots still allowed, nil: no bound
      filled = {}.compare_by_identity     # array => indices a key set

      self.each do |k, v|
        toks = k.to_s
                 .gsub(/\[(\d+)\]/) { "#{sep}#{$1}" }   # sep literal, even '\\'
                 .split(sep).reject(&:empty?)
                 .map { |t| t.match?(/\A\d+\z/) ? t.to_i : t }
        budget += toks.size if budget

        cur = out
        toks.each_with_index do |t, i|
          last = (i == toks.length - 1)
          nxt  = toks[i + 1]

          if cur.is_a?(Array)
            unless t.is_a?(Integer)
              raise ArgumentError, "#{k.inspect}: #{t.inspect} under an array"
            end
            if max_index && t > max_index
              raise ArgumentError, "#{k.inspect}: index #{t} over max_index #{max_index}"
            end
            if budget && t >= cur.size
              budget -= t + 1 - cur.size
              if budget.negative?
                raise ArgumentError, "#{k.inspect}: arrays over max_index #{max_index} " \
                                     "slots, plus one per key segment"
              end
            end
          elsif mapper && t.is_a?(String)
            t = mapper.call(t)      # hash keys only, not integer ones
          end

          # (`cur[t] = v and break` would not break on a nil or false v)
          # An array slot is set when a key set it, nil leaf included:
          # not when it reads nil, which a gap below an index does too
          set = cur.is_a?(Array) ? filled[cur]&.include?(t) : cur.key?(t)
          (filled[cur] ||= Set.new) << t if cur.is_a?(Array)

          if last
            if branch.(cur[t])
              raise ArgumentError, "#{k.inspect}: a leaf where other keys branch"
            end
            cur[t] = v
            break
          end

          if !set
            cur[t] = nxt.is_a?(Integer) ? [] : {}
          elsif !branch.(cur[t])
            raise ArgumentError, "#{k.inspect}: a branch where another key is a leaf"
          end
          cur = cur[t]
        end
      end

      out
    end
  end
end
end
