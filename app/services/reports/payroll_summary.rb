module Reports
  # Aggregates a PayrollPeriod into summary totals + per-employee rows.
  # Used by both the JSON endpoint and the CSV exporter.
  class PayrollSummary
    def self.call(period:)
      new(period: period).call
    end

    def initialize(period:)
      @period = period
    end

    def call
      entries = @period.payroll_entries.includes(:user).order("users.last_name")

      {
        period_id:    @period.id,
        period_label: @period.period_label,
        status:       @period.status,
        branch_id:    @period.branch_id,
        working_days: @period.working_days,
        generated_at: @period.generated_at,
        finalized_at: @period.finalized_at,
        totals:       build_totals(entries),
        entries:      entries.map { |e| entry_row(e) }
      }
    end

    private

    def build_totals(entries)
      {
        employees:        entries.size,
        base_salary:      entries.sum(:base_salary).to_f.round(2),
        deductions:       entries.sum(:total_deductions).to_f.round(2),
        overtime:         entries.sum(:total_overtime).to_f.round(2),
        bonuses:          entries.sum(:total_bonuses).to_f.round(2),
        advances_deducted: entries.sum(:advances_deducted).to_f.round(2),
        net_salary:       entries.sum(:net_salary).to_f.round(2)
      }
    end

    def entry_row(entry)
      {
        user_id:           entry.user_id,
        full_name:         entry.user.full_name,
        salary_type:       entry.salary_type,
        base_salary:       entry.base_salary.to_f,
        working_days:      entry.working_days,
        days_worked:       entry.days_worked,
        total_deductions:  entry.total_deductions.to_f,
        total_overtime:    entry.total_overtime.to_f,
        total_bonuses:     entry.total_bonuses.to_f,
        advances_deducted: entry.advances_deducted.to_f,
        net_salary:        entry.net_salary.to_f,
        status:            entry.status
      }
    end
  end
end
