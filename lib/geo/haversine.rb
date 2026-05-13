module Geo
  module Haversine
    EARTH_RADIUS_METERS = 6_371_000

    # Returns the great-circle distance in metres between two lat/lng points.
    def self.distance(lat1, lon1, lat2, lon2)
      lat1_r = lat1.to_f * Math::PI / 180
      lat2_r = lat2.to_f * Math::PI / 180
      dlat   = (lat2.to_f - lat1.to_f) * Math::PI / 180
      dlon   = (lon2.to_f - lon1.to_f) * Math::PI / 180

      a = Math.sin(dlat / 2)**2 +
          Math.cos(lat1_r) * Math.cos(lat2_r) * Math.sin(dlon / 2)**2

      EARTH_RADIUS_METERS * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    end
  end
end
