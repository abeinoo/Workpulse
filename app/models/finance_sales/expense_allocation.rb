class ExpenseAllocation < ApplicationRecord
  belongs_to :expense
  belongs_to :branch

  validates :allocation_percentage,
            numericality: { greater_than: 0, less_than_or_equal_to: 100 }
  validates :allocated_amount, numericality: { greater_than_or_equal_to: 0 }
  # One row per branch per expense is validated on the parent
  # (Expense#allocations_consistent_when_shared), over the rows actually being
  # saved. A per-row `uniqueness` check here would query the database, so it
  # could neither see two new duplicate rows nor ignore a row that is being
  # removed in the same save (remove branch A, re-add branch A). The unique
  # index on (expense_id, branch_id) remains the last line of defence.
  validate  :branch_in_expense_business

  scope :for_branch, ->(branch_id) { where(branch_id: branch_id) if branch_id.present? }

  private

  def branch_in_expense_business
    return if branch.nil? || expense.nil?

    errors.add(:branch, :invalid) if branch.business_id != expense.business_id
  end
end
