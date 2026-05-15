class PayrollEntry < ApplicationRecord
  belongs_to :payroll_period
  belongs_to :user
  has_many   :payroll_line_items, dependent: :destroy

  STATUSES = %w[draft approved disputed].freeze

  enum :status, { draft: "draft", approved: "approved", disputed: "disputed" }

  validates :user_id, uniqueness: { scope: :payroll_period_id }
  validates :base_salary, :net_salary, presence: true
  validates :working_days, :days_worked,
            numericality: { greater_than_or_equal_to: 0 }

  delegate :branch_id, :period_label, :draft?, to: :payroll_period, prefix: false, allow_nil: true

  def gross_salary
    base_salary + total_overtime + total_bonuses
  end

  def total_adjustments
    total_bonuses - total_deductions - advances_deducted
  end

  # Recomputes stored totals from current line item statuses. Call this after
  # any line item review action (approve / reject / waive) so that net_salary
  # stays in sync without fragile per-action increment/decrement logic.
  def recalculate_totals!
    items = payroll_line_items.reload

    # Only approved items affect the employee's pay.
    active = items.select(&:approved?)

    deductions = active.reject(&:advance_deduction?).select(&:deduction?).sum { |li| li.amount.abs }
    overtime   = active.select(&:overtime?).sum(&:amount)
    bonuses    = active.select { |li| %w[bonus commission reward].include?(li.item_type) }.sum(&:amount)
    advances   = active.select(&:advance_deduction?).sum { |li| li.amount.abs }

    net = base_salary.to_f - deductions + overtime + bonuses - advances

    update!(
      total_deductions:  deductions.round(2),
      total_overtime:    overtime.round(2),
      total_bonuses:     bonuses.round(2),
      advances_deducted: advances.round(2),
      net_salary:        net.round(2)
    )
  end
end
