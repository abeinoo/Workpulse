class ExpenseTagging < ApplicationRecord
  belongs_to :expense
  belongs_to :expense_tag

  validates :expense_tag_id, uniqueness: { scope: :expense_id }
  # A tag must belong to the expense's business (SEC-M2-12) — same rule as
  # ExpenseAllocation#branch_in_expense_business.
  validate  :tag_in_expense_business

  private

  def tag_in_expense_business
    return if expense_tag.nil? || expense.nil?

    errors.add(:expense_tag, :invalid) if expense_tag.business_id != expense.business_id
  end
end
