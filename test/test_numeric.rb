require_relative 'helper'
require 'refinery/deg-rad'

class TestDegRad < Minitest::Test
    using Refinery::DegRad

    def test_round_trip
        assert_in_delta Math::PI, 180.to_rad
        assert_in_delta 180.0,    Math::PI.to_deg
    end

    def test_negative_angles_are_folded_positive_by_default
        assert_in_delta 270.0, (-Math::PI / 2).to_deg
        assert_in_delta(-90.0, (-Math::PI / 2).to_deg(false))
    end
end
