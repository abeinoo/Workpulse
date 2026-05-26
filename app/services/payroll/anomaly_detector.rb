module Payroll
  # Scans payroll entries for operational anomalies and returns structured
  # Anomaly objects sorted by severity (danger → warning → info).
  #
  # Replaces the inline detect_payroll_alerts helper in the controller so
  # the logic is testable, reusable, and richer than the original.
  class AnomalyDetector
    OVERTIME_THRESHOLD   = 0.30   # OT > 30% of base
    DEDUCTION_THRESHOLD  = 0.40   # Deductions > 40% of base
    LOW_DAYS_THRESHOLD   = 0.50   # Days worked < 50% of working days
    SALARY_SPIKE_THRESHOLD = 0.30 # Net change vs prev month > ±30%

    Anomaly = Struct.new(:severity, :code, :message, :affected, keyword_init: true)

    def initialize(period:, entries:, pending_count: 0)
      @period        = period
      @entries       = entries.to_a
      @pending_count = pending_count
      @prev_entries  = load_prev_entries
    end

    def detect
      [
        *detect_negative_net,
        *detect_paid_zero_attendance,
        *detect_zero_attendance,
        *detect_salary_spikes,
        *detect_abnormal_overtime,
        *detect_high_deductions,
        *detect_low_attendance,
        *detect_missing_checkouts,
        *detect_pending_items,
      ]
    end

    private

    # ── Detectors ──────────────────────────────────────────────────────────

    def detect_negative_net
      affected = @entries.select { |e| e.net_salary < 0 }
      return [] if affected.empty?

      [ Anomaly.new(
          severity: :danger,
          code:     :negative_net,
          message:  I18n.t("payroll.anomalies.negative_net", count: affected.size),
          affected: affected
        ) ]
    end

    def detect_paid_zero_attendance
      affected = @entries.select { |e| e.days_worked.to_i.zero? && e.net_salary > 0 }
      return [] if affected.empty?

      [ Anomaly.new(
          severity: :danger,
          code:     :paid_zero_attendance,
          message:  I18n.t("payroll.anomalies.paid_zero_attendance", count: affected.size),
          affected: affected
        ) ]
    end

    def detect_zero_attendance
      # Only the unpaid variant — paid zero is already a danger above.
      affected = @entries.select { |e| e.days_worked.to_i.zero? && e.net_salary <= 0 }
      return [] if affected.empty?

      [ Anomaly.new(
          severity: :warning,
          code:     :zero_attendance,
          message:  I18n.t("payroll.anomalies.zero_attendance", count: affected.size),
          affected: affected
        ) ]
    end

    def detect_salary_spikes
      return [] if @prev_entries.empty?

      affected = @entries.select do |e|
        prev = @prev_entries[e.user_id]
        next false unless prev && prev.net_salary.to_f > 0

        change = (e.net_salary.to_f - prev.net_salary.to_f).abs / prev.net_salary.to_f
        change > SALARY_SPIKE_THRESHOLD
      end
      return [] if affected.empty?

      pct = (SALARY_SPIKE_THRESHOLD * 100).to_i
      [ Anomaly.new(
          severity: :warning,
          code:     :salary_spike,
          message:  I18n.t("payroll.anomalies.salary_spike", count: affected.size, threshold: pct),
          affected: affected
        ) ]
    end

    def detect_abnormal_overtime
      affected = @entries.select { |e|
        e.base_salary > 0 && e.total_overtime > e.base_salary * OVERTIME_THRESHOLD
      }
      return [] if affected.empty?

      pct = (OVERTIME_THRESHOLD * 100).to_i
      [ Anomaly.new(
          severity: :warning,
          code:     :abnormal_overtime,
          message:  I18n.t("payroll.anomalies.abnormal_overtime", count: affected.size, threshold: pct),
          affected: affected
        ) ]
    end

    def detect_high_deductions
      affected = @entries.select { |e|
        e.base_salary > 0 && e.total_deductions > e.base_salary * DEDUCTION_THRESHOLD
      }
      return [] if affected.empty?

      pct = (DEDUCTION_THRESHOLD * 100).to_i
      [ Anomaly.new(
          severity: :warning,
          code:     :high_deductions,
          message:  I18n.t("payroll.anomalies.high_deductions", count: affected.size, threshold: pct),
          affected: affected
        ) ]
    end

    def detect_low_attendance
      affected = @entries.select { |e|
        e.working_days > 0 &&
          !e.days_worked.to_i.zero? &&
          e.days_worked.to_f / e.working_days < LOW_DAYS_THRESHOLD
      }
      return [] if affected.empty?

      pct = (LOW_DAYS_THRESHOLD * 100).to_i
      [ Anomaly.new(
          severity: :info,
          code:     :low_attendance,
          message:  I18n.t("payroll.anomalies.low_attendance", count: affected.size, threshold: pct),
          affected: affected
        ) ]
    end

    def detect_missing_checkouts
      missing_ids = AttendanceRecord
        .for_business(@period.business)
        .for_period(@period.period_start, @period.period_end)
        .incomplete
        .pluck(:user_id)
        .to_set

      return [] if missing_ids.empty?

      affected = @entries.select { |e| missing_ids.include?(e.user_id) }
      return [] if affected.empty?

      [ Anomaly.new(
          severity: :info,
          code:     :missing_checkouts,
          message:  I18n.t("payroll.anomalies.missing_checkouts", count: affected.size),
          affected: affected
        ) ]
    end

    def detect_pending_items
      return [] unless @pending_count > 0

      [ Anomaly.new(
          severity: :warning,
          code:     :pending_items,
          message:  I18n.t("payroll.anomalies.pending_items", count: @pending_count),
          affected: []
        ) ]
    end

    # ── Helpers ────────────────────────────────────────────────────────────

    def load_prev_entries
      m, y = prev_month_and_year
      prev = PayrollPeriod.find_by(business_id: @period.business_id, period_year: y, period_month: m)
      return {} unless prev

      prev.payroll_entries.index_by(&:user_id)
    end

    def prev_month_and_year
      m = @period.period_month - 1
      y = @period.period_year
      m == 0 ? [12, y - 1] : [m, y]
    end
  end
end
