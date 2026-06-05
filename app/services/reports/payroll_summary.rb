module Reports
  # Aggregates a PayrollPeriod into summary totals + per-employee rows.
  # Used by both the JSON endpoint and the CSV exporter.
  #
  # Pass `entries:` to supply a pre-scoped relation (e.g. from policy_scope) so
  # that totals and rows reflect only the records the caller is authorised to see.
  # When omitted the full period entry set is used (owner / admin callers).
  class PayrollSummary
    def self.call(period:, entries: nil)
      new(period: period, entries: entries).call
    end

    def initialize(period:, entries: nil)
      @period  = period
      @entries = entries
    end

    def call
      entries = resolved_entries

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

    def resolved_entries
      (@entries || @period.payroll_entries).includes(:user).order("users.last_name")
    end

    def build_totals(entries)
      {
        employees:            entries.size,
        base_salary:          entries.sum(:base_salary).to_f.round(2),
        deductions:           entries.sum(:total_deductions).to_f.round(2),
        overtime:             entries.sum(:total_overtime).to_f.round(2),
        calculated_overtime:  entries.sum(:calculated_overtime_pay).to_f.round(2),
        overtime_difference:  (entries.sum(:calculated_overtime_pay).to_f - entries.sum(:total_overtime).to_f).round(2),
        bonuses:              entries.sum(:total_bonuses).to_f.round(2),
        already_paid_total:   entries.sum(:already_paid_total).to_f.round(2),
        advances_deducted:    entries.sum(:advances_deducted).to_f.round(2),
        obligations_deducted: entries.sum(:obligations_deducted).to_f.round(2),
        net_salary:           entries.sum(:net_salary).to_f.round(2)
      }
    end

    def entry_row(entry)
      {
        user_id:              entry.user_id,
        full_name:            entry.user.full_name,
        salary_type:          entry.salary_type,
        base_salary:          entry.base_salary.to_f,
        working_days:         entry.working_days,
        days_worked:          entry.days_worked,
        total_deductions:     entry.total_deductions.to_f,
        total_overtime:       entry.total_overtime.to_f,
        calculated_overtime:  entry.calculated_overtime_pay.to_f,
        approved_overtime:    entry.payable_overtime_pay,
        overtime_difference:  entry.overtime_difference,
        overtime_overridden:  entry.overtime_overridden?,
        total_bonuses:        entry.total_bonuses.to_f,
        already_paid_total:   entry.already_paid_total.to_f,
        advances_deducted:    entry.advances_deducted.to_f,
        obligations_deducted: entry.obligations_deducted.to_f,
        net_salary:           entry.net_salary.to_f,
        status:               entry.status
      }
    end
  end
end
