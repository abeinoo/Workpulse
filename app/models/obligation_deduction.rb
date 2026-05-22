class ObligationDeduction < ApplicationRecord
  belongs_to :employee_obligation
  belongs_to :payroll_period

  validates :deducted_amount, :remaining_before, :remaining_after,
            presence: true, numericality: { greater_than_or_equal_to: 0 }

  # Decrement the obligation balance as soon as the snapshot is persisted.
  # This keeps `remaining_amount` accurate from the moment payroll is generated,
  # preventing a second period from over-deducting an already-committed balance.
  before_create  :decrement_obligation_balance

  # Restore balance when the snapshot is destroyed (payroll regeneration).
  before_destroy :restore_obligation_balance

  private

  def decrement_obligation_balance
    employee_obligation.repay!(deducted_amount)
  end

  def restore_obligation_balance
    employee_obligation.restore!(deducted_amount)
  end
end
