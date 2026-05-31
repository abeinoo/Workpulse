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

  # The current business day for "now". Use this anywhere code asks
  # "what is today?" for attendance — it respects both the business
  # timezone and the configured business_day_start_hour, unlike
  # Date.current (UTC calendar) or Time.current.in_time_zone(tz).to_date
  # (timezone-aware but rolls over at midnight, ignoring the start hour).
  def self.current(context:, now: Time.current)
    work_date_for(now, context: context)
  end

  # Explicit alias for work_date_for — reads clearly at call sites that
  # resolve the business day for a specific timestamp (e.g. a punch).
  def self.for_timestamp(timestamp, context:)
    work_date_for(timestamp, context: context)
  end
end
