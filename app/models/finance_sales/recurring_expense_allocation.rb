class RecurringExpenseAllocation < ApplicationRecord
  belongs_to :recurring_expense
  belongs_to :branch

  validates :allocation_percentage,
            numericality: { greater_than: 0, less_than_or_equal_to: 100 }
  validates :branch_id, uniqueness: { scope: :recurring_expense_id }
  validate  :branch_in_same_business

  private

  def branch_in_same_business
    return if branch.nil? || recurring_expense.nil?

    errors.add(:branch, :invalid) if branch.business_id != recurring_expense.business_id
  end
end
