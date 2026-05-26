module Attendance
  # Detects attendance anomalies for a user over a date range.
  # Returns an array of Anomaly structs, sorted by severity.
  #
  # Usage:
  #   Attendance::AnomalyDetector.new(user: user, from: date, to: date).detect
  class AnomalyDetector
    REPEAT_THRESHOLD        = 3   # occurrences in window = pattern
    LATE_MINUTES_SEVERE     = 30  # minutes late = severe lateness
    OVERTIME_WEEKLY_HOURS   = 10  # hours/week = excessive
    PUNCH_GAP_MINUTES       = 3   # suspiciously short shift (minutes)
    SHIFT_WINDOW_BUFFER_MIN = 60  # minutes outside shift start = anomalous

    Anomaly = Struct.new(
      :user, :code, :severity, :message, :count, :dates,
      keyword_init: true
    )

    # records: optional pre-loaded array — pass when running for many users to avoid N+1
    def initialize(user:, from:, to:, records: nil)
      @user    = user
      @from    = from
      @to      = to
      @records = records
    end

    def detect
      results = [
        *detect_repeated_lateness,
        *detect_repeated_early_leave,
        *detect_excessive_overtime,
        *detect_suspicious_punches,
        *detect_missed_checkouts,
        *detect_outside_shift_window,
        *detect_biometric_mismatch
      ]
      results.sort_by { |a| severity_rank(a.severity) }
    end

    # Convenience: run for multiple users and return a flat array.
    # Batch-loads all records in one query to avoid N+1.
    def self.scan_users(users:, from:, to:)
      all_records = AttendanceRecord
        .where(user: users, work_date: from..to)
        .order(:work_date)
        .to_a
        .group_by(&:user_id)

      users.flat_map { |u|
        new(user: u, from: from, to: to, records: all_records[u.id] || []).detect
      }
    end

    private

    def records
      @records ||= AttendanceRecord
        .where(user: @user)
        .where(work_date: @from..@to)
        .order(:work_date)
        .to_a
    end

    # ── Detectors ────────────────────────────────────────────────────────────

    def detect_repeated_lateness
      late = records.select { |r| r.late? || (r.late_minutes.to_i > 0) }
      return [] if late.size < REPEAT_THRESHOLD

      severe = late.select { |r| r.late_minutes.to_i >= LATE_MINUTES_SEVERE }

      anomalies = []
      anomalies << Anomaly.new(
        user:     @user,
        code:     :repeated_lateness,
        severity: :warning,
        message:  I18n.t("attendance.anomalies.repeated_lateness",
                         count: late.size, name: full_name),
        count:    late.size,
        dates:    late.map(&:work_date)
      )

      if severe.size >= REPEAT_THRESHOLD
        anomalies << Anomaly.new(
          user:     @user,
          code:     :severe_lateness,
          severity: :danger,
          message:  I18n.t("attendance.anomalies.severe_lateness",
                           count: severe.size, name: full_name),
          count:    severe.size,
          dates:    severe.map(&:work_date)
        )
      end

      anomalies
    end

    def detect_repeated_early_leave
      early = records.select { |r| r.early_leave? || r.early_leave_minutes.to_i > 0 }
      return [] if early.size < REPEAT_THRESHOLD

      [ Anomaly.new(
          user:     @user,
          code:     :repeated_early_leave,
          severity: :warning,
          message:  I18n.t("attendance.anomalies.repeated_early_leave",
                           count: early.size, name: full_name),
          count:    early.size,
          dates:    early.map(&:work_date)
        ) ]
    end

    def detect_excessive_overtime
      total_ot = records.sum { |r| r.respond_to?(:overtime_minutes) ? r.overtime_minutes.to_i : 0 }
      weeks    = [ ((@to - @from).to_i / 7.0).ceil, 1 ].max
      avg_weekly_hours = total_ot / 60.0 / weeks

      return [] if avg_weekly_hours < OVERTIME_WEEKLY_HOURS

      [ Anomaly.new(
          user:     @user,
          code:     :excessive_overtime,
          severity: :warning,
          message:  I18n.t("attendance.anomalies.excessive_overtime",
                           hours: avg_weekly_hours.round(1), name: full_name),
          count:    records.count { |r| r.respond_to?(:overtime_minutes) && r.overtime_minutes.to_i > 0 },
          dates:    []
        ) ]
    end

    def detect_suspicious_punches
      # Flags records where worked_minutes is unrealistically short (check-in then immediate check-out)
      suspicious = records.select { |r|
        r.checked_out? &&
          r.worked_minutes.present? &&
          r.worked_minutes.to_i < PUNCH_GAP_MINUTES &&
          r.worked_minutes.to_i >= 0
      }
      return [] if suspicious.empty?

      [ Anomaly.new(
          user:     @user,
          code:     :suspicious_punches,
          severity: :danger,
          message:  I18n.t("attendance.anomalies.suspicious_punches",
                           count: suspicious.size, name: full_name),
          count:    suspicious.size,
          dates:    suspicious.map(&:work_date)
        ) ]
    end

    def detect_missed_checkouts
      missed = records.select { |r| r.incomplete? }
      return [] if missed.size < REPEAT_THRESHOLD

      [ Anomaly.new(
          user:     @user,
          code:     :missed_checkouts,
          severity: :warning,
          message:  I18n.t("attendance.anomalies.missed_checkouts",
                           count: missed.size, name: full_name),
          count:    missed.size,
          dates:    missed.map(&:work_date)
        ) ]
    end

    def detect_outside_shift_window
      outside = records.select do |r|
        next false unless r.shift_assignment_id.present?
        shift = r.shift_assignment&.shift
        next false unless shift&.start_time.present?

        # Compare hour/minute of check_in vs shift start
        tz        = @user.business.timezone_object
        check_in  = r.check_in_at.in_time_zone(tz)
        shift_min = shift.start_time.hour * 60 + shift.start_time.min
        actual_min = check_in.hour * 60 + check_in.min
        (actual_min - shift_min).abs > SHIFT_WINDOW_BUFFER_MIN
      end
      return [] if outside.size < REPEAT_THRESHOLD

      [ Anomaly.new(
          user:     @user,
          code:     :outside_shift_window,
          severity: :info,
          message:  I18n.t("attendance.anomalies.outside_shift_window",
                           count: outside.size, name: full_name),
          count:    outside.size,
          dates:    outside.map(&:work_date)
        ) ]
    end

    def detect_biometric_mismatch
      # Flags users where biometric punch logs exist but attendance was created manually
      # (bio punch logs present but no shift_assignment link — indicating manual override)
      tz = @user.business.timezone_object
      from_utc = tz.local(@from.year, @from.month, @from.day, 0, 0, 0).utc
      to_utc   = tz.local(@to.year,   @to.month,   @to.day,  23, 59, 59).utc

      bio_days = BiometricPunchLog
        .where(employee_id: @user.id)
        .where(punched_at: from_utc..to_utc)
        .pluck(:punched_at)
        .map { |t| t.in_time_zone(tz).to_date }
        .to_set

      return [] if bio_days.empty?

      manual_override = records.select { |r|
        bio_days.include?(r.work_date) && r.shift_assignment_id.nil?
      }
      return [] if manual_override.size < REPEAT_THRESHOLD

      [ Anomaly.new(
          user:     @user,
          code:     :biometric_mismatch,
          severity: :info,
          message:  I18n.t("attendance.anomalies.biometric_mismatch",
                           count: manual_override.size, name: full_name),
          count:    manual_override.size,
          dates:    manual_override.map(&:work_date)
        ) ]
    end

    # ── Helpers ──────────────────────────────────────────────────────────────

    def full_name
      "#{@user.first_name} #{@user.last_name}".strip
    end

    def severity_rank(sev)
      { danger: 0, warning: 1, info: 2 }.fetch(sev.to_sym, 3)
    end
  end
end
