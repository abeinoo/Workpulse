# One payroll entry whose payment was withheld because its employee had an
# active SalaryPaymentHold when the period was marked paid
# (Payroll::SalaryWithholder, inside Payroll::Approver's paid transition).
#
# It stores no amount: the held amount is the entry's net_salary, which cannot
# change once the period is finalized — so there is one source of truth.
#
# Lifecycle (each step set once, never cleared; never deleted):
#   withheld   — the period was paid without this entry (held).
#   disbursed  — after the hold was released, the amount was paid
#                (Payroll::ReleasedSalaryPayer); never automatic.
#   voided     — the paid period was reopened (Payroll::Reopener) before the
#                amount was disbursed; the next Mark Paid decides again.
# At most one live (not voided) withholding per entry (partial unique index).
class SalaryPaymentWithholding < ApplicationRecord
  belongs_to :business
  belongs_to :payroll_entry
  belongs_to :salary_payment_hold
  belongs_to :withheld_by,  class_name: "User"
  belongs_to :disbursed_by, class_name: "User", optional: true
  belongs_to :voided_by,    class_name: "User", optional: true

  validates :withheld_at, presence: true
  validate  :same_business
  validate  :lifecycle_is_final, on: :update

  scope :live,        -> { where(voided_at: nil) }
  scope :outstanding, -> { live.where(disbursed_at: nil) }
  scope :disbursed,   -> { where.not(disbursed_at: nil) }

  before_destroy(prepend: true) { raise ActiveRecord::ReadOnlyRecord, "salary payment withholdings are never deleted" }

  def live?        = voided_at.nil?
  def disbursed?   = disbursed_at.present?
  def outstanding? = live? && !disbursed?

  # Held: outstanding while its hold is still active. Payable: outstanding
  # after the hold was released.
  def held?    = outstanding? && salary_payment_hold.active?
  def payable? = outstanding? && salary_payment_hold.released?

  # The held amount — the entry's frozen net salary.
  def amount = payroll_entry.net_salary

  private

  def same_business
    return if business_id.nil?

    errors.add(:payroll_entry, :invalid) if payroll_entry && payroll_entry.payroll_period&.business_id != business_id
    errors.add(:salary_payment_hold, :invalid) if salary_payment_hold && salary_payment_hold.business_id != business_id
    if payroll_entry && salary_payment_hold && payroll_entry.user_id != salary_payment_hold.user_id
      errors.add(:salary_payment_hold, :invalid)
    end
  end

  # What was withheld never changes; disbursement and void are set once.
  def lifecycle_is_final
    %w[business_id payroll_entry_id salary_payment_hold_id withheld_at withheld_by_id].each do |field|
      errors.add(field.to_sym, :invalid) if will_save_change_to_attribute?(field)
    end
    { disbursed_at_was => %w[disbursed_at disbursed_by_id disbursement_note],
      voided_at_was    => %w[voided_at voided_by_id void_reason] }.each do |was, fields|
      next unless was

      fields.each { |field| errors.add(field.to_sym, :invalid) if will_save_change_to_attribute?(field) }
    end
  end
end
