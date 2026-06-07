class Warehouse < ApplicationRecord
  belongs_to :business

  has_many :goods_receipts,      dependent: :restrict_with_error
  has_many :stock_issues,        dependent: :restrict_with_error
  has_many :inventory_movements, dependent: :restrict_with_error
  has_many :warehouse_assignments, dependent: :destroy
  has_many :assigned_users, through: :warehouse_assignments, source: :user

  STATUSES = %w[active inactive].freeze
  enum :status, { active: "active", inactive: "inactive" }

  validates :name, presence: true, length: { maximum: 120 }
  validates :name, uniqueness: { scope: :business_id, case_sensitive: false }

  scope :for_business, ->(business) { where(business: business) }
  scope :ordered,      -> { order(:name) }
end
