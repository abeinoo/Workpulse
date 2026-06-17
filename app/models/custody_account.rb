class CustodyAccount < ApplicationRecord
  belongs_to :business
  belongs_to :user
  belongs_to :branch, optional: true

  has_many :custody_transactions, dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 120 }
  validates :user_id, uniqueness: { scope: :business_id, message: :one_per_employee }
  validates :current_balance, numericality: true
  validate  :user_in_same_business
  validate  :branch_in_same_business

  scope :for_business, ->(business)  { where(business: business) }
  scope :for_user,     ->(user_id)   { where(user_id: user_id) if user_id.present? }
  scope :active,       -> { where(active: true) }
  scope :ordered,      -> { order(:name) }

  # The authoritative balance: SUM of non-voided transaction amounts (stored
  # signed: funding/positive adjustments +, expenses/returns −). The
  # current_balance column is only a cache — never trusted on its own.
  def computed_balance
    custody_transactions.active.sum(:amount)
  end

  # Refresh the cached balance from the ledger. Called after every write.
  def refresh_balance!
    update_column(:current_balance, computed_balance)
  end

  private

  def user_in_same_business
    return if user.nil? || business_id.nil?

    errors.add(:user, :invalid) if user.business_id != business_id
  end

  def branch_in_same_business
    return if branch.nil? || business_id.nil?

    errors.add(:branch, :invalid) if branch.business_id != business_id
  end
end
