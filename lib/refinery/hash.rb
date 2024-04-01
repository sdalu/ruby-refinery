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
end
