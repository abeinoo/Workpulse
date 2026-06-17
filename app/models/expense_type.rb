class ExpenseType < ApplicationRecord
  belongs_to :business
  belongs_to :expense_category

  has_many :expenses,           dependent: :restrict_with_error
  has_many :recurring_expenses, dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 120 },
                   uniqueness: { scope: :expense_category_id, case_sensitive: false }
  validate :category_in_same_business

  scope :for_business, ->(business) { where(business: business) }
  scope :active,       -> { where(active: true) }
  scope :ordered,      -> { order(:name) }
  scope :for_category, ->(category_id) { where(expense_category_id: category_id) if category_id.present? }

  private

  # A type's category must belong to the same business — prevents wiring a type
  # under another tenant's category.
  def category_in_same_business
    return if expense_category.nil? || business_id.nil?

    errors.add(:expense_category, :invalid) if expense_category.business_id != business_id
  end
end
