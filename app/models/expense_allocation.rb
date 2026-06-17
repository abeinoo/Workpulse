class ExpenseAllocation < ApplicationRecord
  belongs_to :expense
  belongs_to :branch

  validates :allocation_percentage,
            numericality: { greater_than: 0, less_than_or_equal_to: 100 }
  validates :allocated_amount, numericality: { greater_than_or_equal_to: 0 }
  validates :branch_id, uniqueness: { scope: :expense_id }
  validate  :branch_in_expense_business

  scope :for_branch, ->(branch_id) { where(branch_id: branch_id) if branch_id.present? }

  private

  def branch_in_expense_business
    return if branch.nil? || expense.nil?

    errors.add(:branch, :invalid) if branch.business_id != expense.business_id
  end
end
