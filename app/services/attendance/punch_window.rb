module Attendance
  # The span of time in which a punch can plausibly belong to a user's work date.
  #
  # A punch is inside the window when EITHER:
  #   1. it falls in the work date's business day — the same rule the attendance
  #      system uses to attribute every punch to a work_date
  #      (BusinessDay.work_date_for, rolling over at business_day_start_hour); or
  #   2. it falls within the assigned fixed-time shift's scheduled span, padded by
  #      the attendance system's existing shift-window tolerance
  #      (AnomalyDetector::SHIFT_WINDOW_BUFFER_MIN). The span starts on the work
  #      date and lasts Shift#duration_minutes, so overnight shifts
  #      (e.g. 19:00 → 02:00) extend into the next calendar day naturally —
  #      covering shifts that spill past the business-day boundary.
  #
  # With no shift assignment (or an hour-based shift, which has no fixed clock
  # window) only rule 1 applies — no shift is invented.
  class PunchWindow
    TOLERANCE = AnomalyDetector::SHIFT_WINDOW_BUFFER_MIN.minutes

    attr_reader :work_date, :assignment

    def self.for(user:, work_date:)
      new(user: user, work_date: work_date)
    end

    def initialize(user:, work_date:)
      @business   = user.business
      @work_date  = work_date
      @assignment = Shifts::AssignmentResolver.for(user: user, date: work_date)
    end

    def shift
      assignment&.shift
    end

    def cover?(time)
      return false if time.nil?

      BusinessDay.work_date_for(time, context: @business) == work_date ||
        shift_range&.cover?(time) || false
    end

    # Scheduled shift start/end on this work date (end may be the next calendar
    # day for overnight shifts); nil without a fixed-time shift.
    def shift_starts_at
      return unless shift&.fixed_time? && shift.timed?

      tz.local(work_date.year, work_date.month, work_date.day, shift.start_time.hour, shift.start_time.min)
    end

    def shift_ends_at
      shift_starts_at && shift_starts_at + shift.duration_minutes.minutes
    end

    private

    def shift_range
      return unless shift_starts_at

      (shift_starts_at - TOLERANCE)..(shift_ends_at + TOLERANCE)
    end

    def tz
      @business.timezone_object
    end
  end
end
