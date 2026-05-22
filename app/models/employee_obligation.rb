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
  validates :installment_amount,
            numericality: { greater_than: 0 },
            on: :create
  validates :start_month, presence: true, inclusion: { in: 1..12 }
  validates :start_year,  presence: true, numericality: { only_integer: true, greater_than: 2000 }
  validates :end_month, inclusion: { in: 1..12 }, allow_nil: true
  validate  :end_period_after_start, if: -> { end_year.present? || end_month.present? }

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
    [ installment_amount.to_f, remaining_amount.to_f ].min.round(2)
  end

  # Decrement balance; mark completed when zero. Called by ObligationDeduction before_create.
  def repay!(amount)
    new_remaining = [ remaining_amount.to_f - amount.to_f, 0 ].max.round(2)
    update!(
      remaining_amount: new_remaining,
      status:           new_remaining <= 0 ? "completed" : status
    )
  end

  # Restore balance when an ObligationDeduction snapshot is destroyed (on regeneration).
  def restore!(amount)
    new_remaining = [ remaining_amount.to_f + amount.to_f, total_amount.to_f ].min.round(2)
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

  def start_label
    "#{Date::MONTHNAMES[start_month]} #{start_year}"
  end

  def end_label
    end_year.present? ? "#{Date::MONTHNAMES[end_month]} #{end_year}" : nil
  end

  private

  def end_period_after_start
    unless end_year.present? && end_month.present?
      errors.add(:end_month, :blank) if end_year.present?
      errors.add(:end_year,  :blank) if end_month.present?
      return
    end
    if (end_year * 12 + end_month) < (start_year * 12 + start_month)
      errors.add(:end_month, "must be on or after the start period")
    end
  end
end
