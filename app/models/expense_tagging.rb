class ExpenseTagging < ApplicationRecord
  belongs_to :expense
  belongs_to :expense_tag

  validates :expense_tag_id, uniqueness: { scope: :expense_id }
end
