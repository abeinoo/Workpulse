# A Salary Payment Hold: HR blocks PAYMENT of an employee's salary — never its
# calculation. Payroll keeps calculating every entry normally; while the hold is
# active, marking a period paid withholds the employee's entry
# (SalaryPaymentWithholding) and new salary advances are not paid out.
#
# The hold stays active across every later period until it is released. It is
# never deleted, and it is released exactly once (released_at, released_by,
# release_reason — set together, then frozen). Releasing pays nothing: it only
# makes the withheld entries payable (Payroll::ReleasedSalaryPayer).
#
# At most one active hold per employee (partial unique index
# index_salary_payment_holds_one_active_per_user). Created and released only
# through Payroll::SalaryHoldCreator / Payroll::SalaryHoldReleaser.
class SalaryPaymentHold < ApplicationRecord
  REASONS = %w[missing_documents incomplete_hiring_paperwork pending_hr_review administrative_issue other].freeze

  belongs_to :business
  belongs_to :user
  belongs_to :created_by,  class_name: "User"
  belongs_to :released_by, class_name: "User", optional: true
  has_many   :salary_payment_withholdings, dependent: :restrict_with_exception

  validates :reason, inclusion: { in: REASONS }
  validates :effective_from, presence: true
  validates :notes, presence: true, if: -> { reason == "other" }
  validate  :same_business
  validate  :release_is_final, on: :update
  validate  :hold_fields_frozen, on: :update

  scope :active,   -> { where(released_at: nil) }
  scope :released, -> { where.not(released_at: nil) }
  # Active holds that cover a payroll period: in force on or before its last day.
  scope :covering, ->(period) { active.where(effective_from: ..period.period_end) }

  before_destroy(prepend: true) { raise ActiveRecord::ReadOnlyRecord, "salary payment holds are never deleted" }

  def active?   = released_at.nil?
  def released? = !active?

  def covers?(period) = active? && effective_from <= period.period_end

  private

  def same_business
    return if business_id.nil?

    { user: user, created_by: created_by, released_by: released_by }.each do |name, person|
      errors.add(name, :invalid) if person && person.business_id != business_id
    end
  end

  # Released once: the release fields can be set, never changed or cleared.
  def release_is_final
    return unless released_at_was

    %w[released_at released_by_id release_reason].each do |field|
      errors.add(field.to_sym, :invalid) if will_save_change_to_attribute?(field)
    end
  end

  # What the hold is (who, from when, why) never changes after creation.
  def hold_fields_frozen
    %w[business_id user_id effective_from reason notes created_by_id].each do |field|
      errors.add(field.to_sym, :invalid) if will_save_change_to_attribute?(field)
    end
  end
end
