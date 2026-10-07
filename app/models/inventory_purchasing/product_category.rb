class ProductCategory < ApplicationRecord
  belongs_to :business

  has_many :products, dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 120 }
  validates :name, uniqueness: { scope: :business_id, case_sensitive: false }

  scope :for_business, ->(business) { where(business: business) }
  scope :ordered,      -> { order(:name) }
  scope :active,       -> { where(active: true) }
end
