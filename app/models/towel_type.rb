class TowelType < ApplicationRecord
  belongs_to :business

  has_many :towel_ledger_entries,       dependent: :restrict_with_error
  has_many :towel_transfers,            dependent: :restrict_with_error
  has_many :laundry_batches,            dependent: :restrict_with_error
  has_many :towel_adjustments,          dependent: :restrict_with_error
  has_many :laundry_standard_cost_rates, dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 120 },
                   uniqueness: { scope: :business_id, case_sensitive: false }

  scope :for_business, ->(business) { where(business: business) }
  scope :active,       -> { where(active: true) }
end
