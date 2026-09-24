class EmployeeObligation < ApplicationRecord
  OBLIGATION_TYPES = %w[cash_loan equipment penalty_installment custom].freeze
  STATUSES         = %w[active paused completed cancelled].freeze

  # Payroll periods past this point are immutable (matches PayrollPeriod#locked?).
  LOCKING_PERIOD_STATUSES = %w[finalized paid].freeze

  belongs_to :user
  belongs_to :business
  belongs_to :created_by, class_name: "User"
  has_many   :obligation_deductions, dependent: :destroy
  has_many   :obligation_postponements, dependent: :destroy

  enum :obligation_type, {
    cash_loan:           "cash_loan",
    equipment:           "equipment",
    penalty_installment: "penalty_installment",
    custom:              "custom"
  }

  enum :status, {
    active:    "active",
    paused:    "paused",
    completed: "completed",
    cancelled: "cancelled"
  }

  validates :obligation_type, :title, :status, presence: true
  validates :total_amount, :remaining_amount, :installment_amount,
            presence: true,
            numericality: { greater_than_or_equal_to: 0 }
  validates :total_amount,      numericality: { greater_than: 0 }
  validates :installment_amount, numericality: { greater_than: 0 }
  validates :installments_count,
            presence: true,
            numericality: { only_integer: true, greater_than: 0 }
  validates :start_month, presence: true, inclusion: { in: 1..12 }
  validates :start_year,  presence: true, numericality: { only_integer: true, greater_than: 2000 }
  validates :end_month, inclusion: { in: 1..12 }, allow_nil: true
  validate  :end_period_after_start, if: -> { end_year.present? || end_month.present? }
  validate  :remaining_within_total
  validate  :installment_not_exceeding_total
  validate  :installment_count_consistent

  scope :for_user,       ->(user)     { where(user: user) }
  scope :for_business,   ->(business) { where(business: business) }
  scope :auto_deductible, ->          { where(auto_deduct: true) }

  # ── Index filters ──────────────────────────────────────────────────────────
  # Read-only query scopes for the admin index. Each is a no-op on a blank or
  # unknown value, so a stale/tampered query param never errors or leaks.

  # Employee name, employee code or obligation title (case-insensitive).
  scope :search, ->(term) {
    if term.present?
      q = "%#{sanitize_sql_like(term.to_s.strip)}%"
      joins(:user).where(
        "employee_obligations.title ILIKE :q OR " \
        "CONCAT_WS(' ', users.first_name, users.last_name) ILIKE :q OR " \
        "users.employee_code ILIKE :q", q: q
      )
    end
  }
  scope :for_employee,   ->(user_id) { where(user_id: user_id) if user_id.present? }
  scope :of_type,        ->(type)    { where(obligation_type: type) if type.in?(obligation_types.keys) }
  scope :with_status,    ->(status)  { where(status: status) if status.in?(statuses.keys) }

  # Obligations do not carry a branch — the employee's branch is derived from
  # their active ShiftAssignment (BranchMembership is the single source).
  scope :for_branch, ->(branch_id) {
    where(user_id: BranchMembership.current_member_ids([ branch_id ])) if branch_id.present?
  }

  # Start period (month granularity) within an inclusive range of dates.
  scope :starting_on_or_after, ->(date) {
    where("employee_obligations.start_year * 12 + employee_obligations.start_month >= ?",
          (date.year * 12) + date.month) if date
  }
  scope :starting_on_or_before, ->(date) {
    where("employee_obligations.start_year * 12 + employee_obligations.start_month <= ?",
          (date.year * 12) + date.month) if date
  }

  # Still being collected: a live (active/paused) obligation with a stored
  # remaining_amount above zero. Cancelled obligations are excluded — their
  # leftover remaining_amount is no longer owed or deducted.
  scope :with_outstanding_balance, -> { where(status: %w[active paused]).where("employee_obligations.remaining_amount > 0") }
  scope :fully_repaid,             -> { where(remaining_amount: 0) }

  # Obligations that cover a given payroll period (started on or before, not yet ended).
  scope :covering_period, ->(period) {
    y = period.period_year
    m = period.period_month
    where("(start_year < :y) OR (start_year = :y AND start_month <= :m)", y: y, m: m)
      .where(
        "(end_year IS NULL AND end_month IS NULL) OR " \
        "(end_year > :y) OR " \
        "(end_year = :y AND end_month >= :m)", y: y, m: m
      )
  }

  # The amount to deduct for a given payroll period — never exceeds the
  # remaining balance. Folds in any postponement affecting this period: an
  # installment postponed away from this period deducts nothing here, and a
  # period that absorbed a "next_month" postponement deducts the extra amount
  # on top. Called with no period by specs/callers that only need the flat,
  # unpostponed installment amount.
  def installment_for_period(period = nil)
    base = installment_amount.to_f
    if period
      return 0.0 if postponed_away?(period.period_year, period.period_month)
      base += postponed_into(period.period_year, period.period_month)
    end
    [ base, remaining_amount ].min.round(2)
  end

  # Decrement balance; mark completed when zero. Called by ObligationDeduction before_create.
  def repay!(amount)
    new_remaining = ([ remaining_amount - amount, 0 ].max).round(2)
    update!(
      remaining_amount: new_remaining,
      status:           new_remaining <= 0 ? "completed" : status
    )
  end

  # Restore balance when an ObligationDeduction snapshot is destroyed (on regeneration).
  def restore!(amount)
    new_remaining = ([ remaining_amount + amount, total_amount ].min).round(2)
    update!(
      remaining_amount: new_remaining,
      status:           (new_remaining > 0 && completed?) ? "active" : status
    )
  end

  def repaid_amount
    (total_amount.to_f - remaining_amount.to_f).round(2)
  end

  def percent_repaid
    return 100 if total_amount.to_f <= 0
    ((repaid_amount / total_amount.to_f) * 100).round(1)
  end

  # Returns the remainder after full installments, or 0.0 if evenly divisible.
  def final_installment_amount
    return 0.0 unless total_amount.to_f > 0 && installment_amount.to_f > 0
    remainder = (total_amount.to_f % installment_amount.to_f).round(2)
    remainder.zero? ? 0.0 : remainder
  end

  def even_installments?
    final_installment_amount.zero?
  end

  # Number of full-sized installments (excludes the smaller final one when there's a remainder).
  def full_installments_count
    even_installments? ? installments_count : installments_count - 1
  end

  # Ordered list of {month:, year:, amount:, status:, postponement:} for the
  # complete payment schedule, folding in any ObligationPostponement rows:
  # a postponed installment shows amount 0 with status: :postponed; the
  # period a "next_month" postponement moved into shows the increased
  # amount; each "extend_loan" postponement appends one extra entry after
  # the natural end of the schedule. Total scheduled amount is unchanged —
  # postponement only relocates when an amount is due.
  def installment_schedule
    return [] unless start_month.present? && start_year.present? && installments_count.to_i > 0

    postponements        = obligation_postponements.to_a
    by_original           = postponements.index_by { |p| [ p.original_year, p.original_month ] }
    next_month_postponed  = postponements.select(&:next_month?)
    extended              = postponements.select(&:extend_loan?)

    m, y = start_month, start_year
    base_keys = []
    base_entries = Array.new(installments_count) do |i|
      base_amount = (!even_installments? && i == installments_count - 1) ? final_installment_amount : installment_amount.to_f
      key         = [ y, m ]
      base_keys << key
      postponed   = by_original[key]
      addition    = next_month_postponed.select { |p| p.target_year == y && p.target_month == m }.sum(&:amount).to_f
      entry = {
        month:        m,
        year:         y,
        amount:       (postponed ? 0.0 : (base_amount + addition)).round(2),
        status:       postponed ? :postponed : :scheduled,
        postponement: postponed
      }
      m += 1
      if m > 12
        m = 1
        y += 1
      end
      entry
    end

    # A next_month postponement whose target falls beyond the nominal schedule
    # (postponing the last installment of an open-ended obligation) has no
    # base entry to fold into — it introduces a genuinely new future due date.
    overflow_entries = next_month_postponed
      .reject { |p| base_keys.include?([ p.target_year, p.target_month ]) }
      .map { |p| { month: p.target_month, year: p.target_year, amount: p.amount.round(2), status: :scheduled, postponement: nil } }

    extend_entries = extended.map do |p|
      { month: p.target_month, year: p.target_year, amount: p.amount.round(2), status: :postponed, postponement: p }
    end

    (base_entries + overflow_entries + extend_entries).sort_by { |e| [ e[:year], e[:month] ] }
  end

  # The schedule entry (base or appended) covering a given month/year, or nil
  # if that period falls outside the schedule entirely.
  def scheduled_entry_for(year, month)
    installment_schedule.find { |e| e[:year] == year && e[:month] == month }
  end

  def postponed_away?(year, month)
    obligation_postponements.to_a.any? { |p| p.original_year == year && p.original_month == month }
  end

  def postponed_into(year, month)
    obligation_postponements.to_a
                             .select { |p| p.next_month? && p.target_year == year && p.target_month == month }
                             .sum(&:amount).to_f
  end

  # Whether this obligation has a deduction snapshot for a given period,
  # regardless of that period's own status. A snapshot alone does not mean
  # the installment is "processed" in the business sense — see
  # #period_finalized? for the actual postponement-eligibility test.
  def deducted_for?(year, month)
    obligation_deductions.joins(:payroll_period)
                          .where(payroll_periods: { period_year: year, period_month: month })
                          .exists?
  end

  # The single source of truth for "has this installment actually been
  # processed" — reuses PayrollPeriod's own finalized/paid distinction
  # (PayrollPeriod#locked?, EmployeeObligation::LOCKING_PERIOD_STATUSES).
  # A period in draft, under_review or branch_review_completed is NOT
  # finalized: it may already carry a deduction snapshot (payroll ran a
  # preview calculation), but that snapshot is still fully mutable — exactly
  # like Payroll::ObligationEditor treats it — so a draft-period installment
  # remains postponable even though a snapshot already exists for it.
  #
  # Deliberately scoped to the single period in question — unlike
  # payroll_locked?, which reports whether *any* period this obligation has
  # ever touched is locked (the right gate for editing the obligation's
  # global schedule fields in Payroll::ObligationEditor, but far too broad
  # here: an obligation with a paid June shouldn't block postponing a
  # still-untouched November installment).
  def period_finalized?(year, month)
    PayrollPeriod.for_business(business)
                  .exists?(period_year: year, period_month: month, status: LOCKING_PERIOD_STATUSES)
  end

  def next_period_for(year, month)
    month.to_i == 12 ? [ year.to_i + 1, 1 ] : [ year.to_i, month.to_i + 1 ]
  end

  # Open-ended obligations (no end_month/end_year) always have room for a
  # "next" period. Closed-end obligations cannot be postponed past their
  # configured end.
  def within_window?(year, month)
    return true if end_year.blank? || end_month.blank?
    (year < end_year) || (year == end_year && month <= end_month)
  end

  # An installment can be postponed as long as its payroll period has not
  # been finalized/paid yet (see #period_finalized?), it isn't already
  # postponed, and the obligation itself isn't cancelled or completed. This
  # intentionally does NOT check payroll_locked? (which reports on the
  # obligation as a whole) — see #period_finalized? for why that would be
  # far too broad here.
  def postponable?(year, month)
    (active? || paused?) &&
      !postponed_away?(year, month) &&
      !period_finalized?(year, month) &&
      scheduled_entry_for(year, month).present?
  end

  # "next_month" additionally requires a following period that is still
  # within the schedule's window and hasn't itself been finalized/paid — a
  # following installment whose payroll already closed is immutable.
  def next_month_postponable?(year, month)
    return false unless postponable?(year, month)
    ty, tm = next_period_for(year, month)
    within_window?(ty, tm) && !period_finalized?(ty, tm)
  end

  # "extend_loan" always has somewhere to append to — it never touches an
  # existing period.
  def extend_loan_postponable?(year, month)
    postponable?(year, month)
  end

  # {year:, month:, new_amount:} the next installment would show if this
  # installment's amount were postponed onto it — used to render the exact
  # confirmation message before the user commits. nil when not eligible.
  def next_month_target_amount(year, month)
    return nil unless next_month_postponable?(year, month)
    ty, tm  = next_period_for(year, month)
    current = scheduled_entry_for(ty, tm)&.dig(:amount) || 0.0
    moved   = scheduled_entry_for(year, month)[:amount]
    { year: ty, month: tm, new_amount: (current + moved).round(2) }
  end

  # Once any of this obligation's deductions belongs to a finalized or paid period,
  # its schedule (start/end period, amounts) can no longer be edited — that payroll
  # is immutable. Draft, under_review and branch_review_completed periods remain
  # editable and get recalculated. See EmployeeObligation::LOCKING_PERIOD_STATUSES.
  def payroll_locked?
    obligation_deductions.joins(:payroll_period)
                          .where(payroll_periods: { status: LOCKING_PERIOD_STATUSES })
                          .exists?
  end

  def start_label
    "#{I18n.t("date.month_names")[start_month]} #{start_year}"
  end

  def end_label
    end_year.present? ? "#{I18n.t("date.month_names")[end_month]} #{end_year}" : nil
  end

  private

  def end_period_after_start
    unless end_year.present? && end_month.present?
      errors.add(:end_month, :blank) if end_year.present?
      errors.add(:end_year,  :blank) if end_month.present?
      return
    end
    return unless start_year.present? && start_month.present?
    if (end_year * 12 + end_month) < (start_year * 12 + start_month)
      errors.add(:end_month, "must be on or after the start period")
    end
  end

  def remaining_within_total
    return unless total_amount.present? && remaining_amount.present?
    return unless total_amount > 0
    if remaining_amount > total_amount
      errors.add(:remaining_amount, :exceeds_total, total: total_amount)
    end
  end

  def installment_not_exceeding_total
    return unless total_amount.present? && installment_amount.present?
    return unless total_amount > 0 && installment_amount > 0
    if installment_amount > total_amount
      errors.add(:installment_amount, :exceeds_total, total: total_amount)
    end
  end

  def installment_count_consistent
    return unless total_amount.present? && installment_amount.present? && installments_count.present?
    return unless total_amount > 0 && installment_amount > 0 && installments_count > 0

    expected = (total_amount.to_f / installment_amount.to_f).ceil
    unless installments_count == expected
      errors.add(:installments_count, :inconsistent,
                 total: total_amount, installment: installment_amount,
                 count: installments_count, expected: expected)
    end
  end
end
