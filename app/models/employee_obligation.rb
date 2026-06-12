class EmployeeObligation < ApplicationRecord
  OBLIGATION_TYPES = %w[cash_loan equipment penalty_installment custom].freeze
  STATUSES         = %w[active paused completed cancelled].freeze

  belongs_to :user
  belongs_to :business
  belongs_to :created_by, class_name: "User"
  has_many   :obligation_deductions, dependent: :destroy

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

  # The amount to deduct this period — never exceeds the remaining balance.
  def installment_for_period
    [installment_amount, remaining_amount].min.round(2)
  end

  # Decrement balance; mark completed when zero. Called by ObligationDeduction before_create.
  def repay!(amount)
    new_remaining = ([remaining_amount - amount, 0].max).round(2)
    update!(
      remaining_amount: new_remaining,
      status:           new_remaining <= 0 ? "completed" : status
    )
  end

  # Restore balance when an ObligationDeduction snapshot is destroyed (on regeneration).
  def restore!(amount)
    new_remaining = ([remaining_amount + amount, total_amount].min).round(2)
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

  # Ordered list of {month:, year:, amount:} for the complete payment schedule.
  def installment_schedule
    return [] unless start_month.present? && start_year.present? && installments_count.to_i > 0
    m, y = start_month, start_year
    Array.new(installments_count) do |i|
      amount = (!even_installments? && i == installments_count - 1) ? final_installment_amount : installment_amount.to_f
      entry = { month: m, year: y, amount: amount.round(2) }
      m += 1
      if m > 12
        m = 1
        y += 1
      end
      entry
    end
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
