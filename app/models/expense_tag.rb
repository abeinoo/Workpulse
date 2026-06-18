class ExpenseTag < ApplicationRecord
  belongs_to :business

  has_many :expense_taggings, dependent: :restrict_with_error
  has_many :expenses, through: :expense_taggings

  validates :name, presence: true, length: { maximum: 60 },
                   uniqueness: { scope: :business_id, case_sensitive: false }

  scope :for_business, ->(business) { where(business: business) }
  scope :active,       -> { where(active: true) }
  scope :ordered,      -> { order(:name) }
end
