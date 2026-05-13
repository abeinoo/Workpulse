module BusinessDay
  # Returns the work_date (Date) for a given UTC timestamp.
  #
  # context must respond to:
  #   #timezone_object        → ActiveSupport::TimeZone
  #   #business_day_start_hour → Integer (0–23)
  #
  # Designed to accept a Business or, in future, a Branch that overrides
  # these methods with branch-level settings — call sites need no change.
  def self.work_date_for(timestamp, context:)
    local = timestamp.in_time_zone(context.timezone_object)
    local.hour >= context.business_day_start_hour ? local.to_date : local.to_date - 1
  end
end
