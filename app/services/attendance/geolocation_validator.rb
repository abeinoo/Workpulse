module Attendance
  module GeolocationValidator
    # Returns true when the employee's coordinates are within the branch radius,
    # or when the branch has geolocation enforcement disabled.
    def self.within_radius?(branch:, latitude:, longitude:)
      return true unless branch.geolocation_enabled?
      return false unless latitude.present? && longitude.present?
      return false unless branch.latitude && branch.longitude

      distance = Geo::Haversine.distance(
        branch.latitude,  branch.longitude,
        latitude.to_f, longitude.to_f
      )

      distance <= branch.radius_meters
    end
  end
end
