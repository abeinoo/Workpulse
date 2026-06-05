class PayrollEntry < ApplicationRecord
  belongs_to :payroll_period
  belongs_to :user
  belongs_to :overtime_overridden_by, class_name: "User", optional: true
  has_many   :payroll_line_items, dependent: :destroy

  STATUSES = %w[draft approved disputed].freeze
  # How a manager entered an overtime override (see migration for semantics).
  OVERTIME_OVERRIDE_MODES = %w[minutes amount].freeze

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

  # ── Overtime override ──────────────────────────────────────────────────────
  # The override layer never touches attendance or overtime line items. It only
  # decides how much of the system-calculated overtime is actually payable.
  # total_overtime is kept equal to the payable figure so every downstream
  # consumer (gross/net/reports/snapshot) reflects the override automatically.
  def overtime_overridden?
    overtime_override_mode.present?
  end

  # Payable overtime minutes — the approved value when overridden, else calculated.
  def payable_overtime_minutes
    overtime_overridden? ? approved_overtime_minutes.to_i : calculated_overtime_minutes.to_i
  end

  # Payable overtime money — kept in sync with total_overtime by recalculate_totals!.
  def payable_overtime_pay
    overtime_overridden? ? approved_overtime_pay.to_f : calculated_overtime_pay.to_f
  end

  # How much overtime pay was withheld by the override (>= 0). Drives reports.
  def overtime_difference
    (calculated_overtime_pay.to_f - payable_overtime_pay).round(2)
  end

  # Resolves the payable overtime pay for a given calculated pay, honouring the
  # override mode. "amount" overrides are absolute; "minutes" overrides scale the
  # calculated pay pro-rata at the period's blended overtime rate.
  def resolve_overtime_pay(calculated_pay)
    return calculated_pay.to_f.round(2) unless overtime_overridden?

    case overtime_override_mode
    when "amount"  then approved_overtime_pay.to_f.round(2)
    when "minutes" then prorated_overtime_pay(calculated_pay, approved_overtime_minutes)
    else calculated_pay.to_f.round(2)
    end
  end

  def prorated_overtime_pay(calculated_pay, minutes)
    return 0.0 if calculated_overtime_minutes.to_i.zero?
    (calculated_pay.to_f * minutes.to_i / calculated_overtime_minutes.to_i).round(2)
  end

  BONUS_TYPES = %w[cash_incentive commission].freeze

  def total_adjustments
    total_bonuses - already_paid_total - total_deductions - advances_deducted - obligations_deducted
  end

  # ── Manual deduction waiver reporting ───────────────────────────────────────
  # The approved manual-deduction line items for this entry. Both active and
  # waived ones — the waiver layer decides which are actually applied.
  def approved_manual_deduction_items
    payroll_line_items.select { |li| li.manual_deduction? && li.approved? }
  end

  # Sum of manual deductions that have been waived (excluded from net salary).
  def waived_deductions_total
    approved_manual_deduction_items.select(&:deduction_waived?).sum { |li| li.amount.abs }.round(2)
  end

  # What manual deductions would total with NO waivers applied.
  def original_manual_deductions_total
    approved_manual_deduction_items.sum { |li| li.amount.abs }.round(2)
  end

  # What is actually deducted after waivers (the part the employee still pays).
  def applied_manual_deductions_total
    (original_manual_deductions_total - waived_deductions_total).round(2)
  end

  # True when at least one manual deduction on this entry has been waived.
  def any_deduction_waived?
    approved_manual_deduction_items.any?(&:deduction_waived?)
  end

  # Recomputes stored totals from current approved line items.
  # already_paid bonuses appear in total_bonuses (gross picture) but are also
  # stored in already_paid_total and subtracted from net_salary so the employee
  # is not paid twice.
  def recalculate_totals!
    items  = payroll_line_items.reload
    active = items.select(&:approved?)

    non_financial = ->(li) { li.advance_deduction? || li.obligation_deduction? }
    # Waived manual deductions stay on the entry (visible + audited) but are excluded
    # from the payable figure, so net salary rises by the waived amount automatically.
    deductions    = active.reject(&non_financial).reject(&:deduction_waived?).select(&:deduction?).sum { |li| li.amount.abs }
    # Raw system overtime from attendance line items (the source of truth).
    calculated_ot = active.select(&:overtime?).sum(&:amount).round(2)
    # Payable overtime applies the management override (no-op when not overridden).
    # For "minutes" overrides we re-derive approved_overtime_pay so it stays consistent
    # if the underlying calculated overtime changed.
    overtime      = resolve_overtime_pay(calculated_ot)
    if overtime_overridden? && overtime_override_mode == "minutes"
      self.approved_overtime_pay = overtime
    end
    # ALL bonuses go into total_bonuses — already_paid ones are then separately subtracted
    bonuses       = active.select { |li| BONUS_TYPES.include?(li.item_type) }.sum(&:amount)
    already_paid  = active.select { |li| BONUS_TYPES.include?(li.item_type) && li.already_paid? }.sum(&:amount)
    advances      = active.select(&:advance_deduction?).sum { |li| li.amount.abs }
    obligations   = active.select(&:obligation_deduction?).sum { |li| li.amount.abs }

    # net = what still needs to be paid out this cycle
    net = base_salary.to_f + overtime + bonuses - already_paid - deductions - advances - obligations

    update!(
      total_deductions:        deductions.round(2),
      total_overtime:          overtime.round(2),
      calculated_overtime_pay: calculated_ot,
      approved_overtime_pay:   approved_overtime_pay,
      total_bonuses:        bonuses.round(2),
      already_paid_total:   already_paid.round(2),
      advances_deducted:    advances.round(2),
      obligations_deducted: obligations.round(2),
      net_salary:           net.round(2)
    )
  end
end
