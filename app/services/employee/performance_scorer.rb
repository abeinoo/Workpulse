module Employee
  # Computes a 0–100 performance score for an employee over a date range.
  # Score breakdown:
  #   attendance_consistency  30 pts — days worked / working days
  #   lateness_frequency      25 pts — inverted: fewer late days = higher score
  #   shift_completion        20 pts — checked-out records / checked-in records
  #   overtime_reliability    15 pts — consistent overtime (not erratic)
  #   absence_rate            10 pts — inverted absent count
  #
  # Returns a Result with score (0-100), grade, and per-dimension breakdown.
  class PerformanceScorer
    GRADE_MAP = {
      90..100 => :excellent,
      75..89  => :good,
      55..74  => :fair,
      0..54   => :poor
    }.freeze

    Result = Struct.new(
      :score, :grade, :breakdown,
      :total_days, :late_days, :absent_days, :incomplete_days,
      keyword_init: true
    )

    # records: optional pre-loaded array — pass when scoring many users to avoid N+1
    def self.call(user:, from:, to:, records: nil)
      new(user: user, from: from, to: to, records: records).call
    end

    def initialize(user:, from:, to:, records: nil)
      @user    = user
      @from    = from
      @to      = to
      @records = records
    end

    def call
      records = @records || AttendanceRecord
        .active
        .where(user: @user, work_date: @from..@to)
        .to_a

      calendar_days  = (@to - @from).to_i + 1
      working_days   = (@user.business.working_days_per_month.to_f / 30 * calendar_days).round.clamp(1, calendar_days)
      total_records  = records.size
      late_days      = records.count { |r| r.late? || r.late_minutes.to_i > 0 }
      early_days     = records.count { |r| r.early_leave? || r.early_leave_minutes.to_i > 0 }
      absent_days    = records.count(&:absent?)
      incomplete_days = records.count(&:incomplete?)
      checked_in     = records.count { |r| r.check_in_at.present? }
      checked_out    = records.count { |r| r.checked_out? }

      # ── Dimension scores ─────────────────────────────────────────────────

      # 1. Attendance consistency (30 pts)
      attendance_ratio = working_days > 0 ? (checked_in.to_f / working_days).clamp(0, 1) : 0
      att_score = (attendance_ratio * 30).round

      # 2. Lateness frequency (25 pts) — 0 late = 25, all late = 0
      late_ratio = checked_in > 0 ? (late_days.to_f / checked_in).clamp(0, 1) : 0
      late_score = ((1 - late_ratio) * 25).round

      # 3. Shift completion (20 pts) — checked out / checked in
      completion_ratio = checked_in > 0 ? (checked_out.to_f / checked_in).clamp(0, 1) : 0
      completion_score = (completion_ratio * 20).round

      # 4. Overtime reliability (15 pts) — penalise erratic OT (0 or excessive)
      ot_days = records.count { |r| r.respond_to?(:overtime_minutes) && r.overtime_minutes.to_i > 0 }
      ot_ratio = checked_in > 0 ? (ot_days.to_f / checked_in) : 0
      ot_score = if ot_ratio.zero?
        15  # no overtime is normal/expected
      elsif ot_ratio <= 0.30
        15  # occasional — reliable
      elsif ot_ratio <= 0.60
        10  # frequent — borderline
      else
        5   # excessive — concern
      end

      # 5. Absence rate (10 pts) — invert absent days
      absence_ratio = working_days > 0 ? (absent_days.to_f / working_days).clamp(0, 1) : 0
      absence_score = ((1 - absence_ratio) * 10).round

      total_score = att_score + late_score + completion_score + ot_score + absence_score

      Result.new(
        score:           total_score,
        grade:           grade_for(total_score),
        breakdown:       {
          attendance_consistency: att_score,
          lateness_frequency:     late_score,
          shift_completion:       completion_score,
          overtime_reliability:   ot_score,
          absence_rate:           absence_score
        },
        total_days:      total_records,
        late_days:       late_days,
        absent_days:     absent_days,
        incomplete_days: incomplete_days
      )
    end

    private

    def grade_for(score)
      GRADE_MAP.each { |range, grade| return grade if range.cover?(score) }
      :poor
    end
  end
end
