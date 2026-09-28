module Attendance
  # Classifies a worked duration against the business's review thresholds
  # (Business#attendance_suspicious_duration_hours / _critical_duration_hours).
  # Read-only: a flagged record is surfaced for review, never modified.
  module DurationCheck
    # :critical, :suspicious, or nil when the duration is unremarkable.
    def self.severity(minutes, business:)
      return if minutes.nil?
      return :critical   if minutes > business.attendance_critical_duration_hours * 60
      return :suspicious if minutes > business.attendance_suspicious_duration_hours * 60

      nil
    end

    # The configured hour threshold a severity was measured against.
    def self.threshold_hours(severity, business:)
      severity == :critical ? business.attendance_critical_duration_hours : business.attendance_suspicious_duration_hours
    end
  end
end
