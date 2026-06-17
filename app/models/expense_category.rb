class ExpenseCategory < ApplicationRecord
  belongs_to :business

  has_many :expense_types,       dependent: :destroy
  has_many :expenses,            dependent: :restrict_with_error
  has_many :recurring_expenses,  dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 120 },
                   uniqueness: { scope: :business_id, case_sensitive: false }

  scope :for_business, ->(business) { where(business: business) }
  scope :active,       -> { where(active: true) }
  scope :ordered,      -> { order(:name) }
end
