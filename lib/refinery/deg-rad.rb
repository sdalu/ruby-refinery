module Refinery
module DegRad
    refine Numeric do
        def to_deg(positif=true)
            r = self * 180.0 / Math::PI
            r = (r + 360) % 360 if positif
            r
        end
        def to_rad
            self * Math::PI / 180.0
        end
    end
end
end
