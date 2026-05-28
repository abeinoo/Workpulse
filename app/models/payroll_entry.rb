class PayrollEntry < ApplicationRecord
  belongs_to :payroll_period
  belongs_to :user
  has_many   :payroll_line_items, dependent: :destroy

  STATUSES = %w[draft approved disputed].freeze

  enum :status, { draft: "draft", approved: "approved", disputed: "disputed" }

  # Entries in finalized or paid periods — the only entries employees may see.
  scope :employee_visible, -> {
    joins(:payroll_period).where(payroll_periods: { status: %w[finalized paid] })
  }

  validates :user_id, uniqueness: { scope: :payroll_period_id }
  validates :base_salary, :net_salary, presence: true
  validates :working_days, :days_worked,
            numericality: { greater_than_or_equal_to: 0 }

  delegate :branch_id, :period_label, :draft?, to: :payroll_period, prefix: false, allow_nil: true

  def gross_salary
    base_salary + total_overtime + total_bonuses
  end

  BONUS_TYPES = %w[cash_incentive commission].freeze

  def total_adjustments
    total_bonuses - already_paid_total - total_deductions - advances_deducted - obligations_deducted
  end

  # Recomputes stored totals from current approved line items.
  # already_paid bonuses appear in total_bonuses (gross picture) but are also
  # stored in already_paid_total and subtracted from net_salary so the employee
  # is not paid twice.
  def recalculate_totals!
    items  = payroll_line_items.reload
    active = items.select(&:approved?)

    non_financial = ->(li) { li.advance_deduction? || li.obligation_deduction? }
    deductions    = active.reject(&non_financial).select(&:deduction?).sum { |li| li.amount.abs }
    overtime      = active.select(&:overtime?).sum(&:amount)
    # ALL bonuses go into total_bonuses — already_paid ones are then separately subtracted
    bonuses       = active.select { |li| BONUS_TYPES.include?(li.item_type) }.sum(&:amount)
    already_paid  = active.select { |li| BONUS_TYPES.include?(li.item_type) && li.already_paid? }.sum(&:amount)
    advances      = active.select(&:advance_deduction?).sum { |li| li.amount.abs }
    obligations   = active.select(&:obligation_deduction?).sum { |li| li.amount.abs }

    # net = what still needs to be paid out this cycle
    net = base_salary.to_f + overtime + bonuses - already_paid - deductions - advances - obligations

    update!(
      total_deductions:     deductions.round(2),
      total_overtime:       overtime.round(2),
      total_bonuses:        bonuses.round(2),
      already_paid_total:   already_paid.round(2),
      advances_deducted:    advances.round(2),
      obligations_deducted: obligations.round(2),
      net_salary:           net.round(2)
    )
  end
end
