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

module HashDeflateKeys
  refine Hash do
    def deflate_keys(sep: '.', &mapper)
      out = {}

      self.each do |k, v|
        toks = k.to_s
                 .gsub(/\[(\d+)\]/, "#{sep}\\1")
                 .split(sep).reject(&:empty?)
                 .map { |t| t.match?(/\A\d+\z/) ? t.to_i : t }

        cur = out
        toks.each_with_index do |t, i|
          last = (i == toks.length - 1)
          nxt  = toks[i + 1]

          if cur.is_a?(Array)
            cur[t] = v and break if last
            cur[t] ||= (nxt.is_a?(Integer) ? [] : {})
            cur = cur[t]
          else
            t = mapper.call(t) if mapper
            cur[t] = v and break if last
            cur[t] ||= (nxt.is_a?(Integer) ? [] : {})
            cur = cur[t]
          end
        end
      end

      out
    end
  end
end
end
