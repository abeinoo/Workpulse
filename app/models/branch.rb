class Branch < ApplicationRecord
  belongs_to :business
  belongs_to :branch_manager, class_name: "User", optional: true
  belongs_to :area_manager,   class_name: "User", optional: true
  has_many :shift_assignments,   dependent: :nullify
  has_many :attendance_records,  dependent: :destroy
  has_many :payroll_periods,     dependent: :destroy

  # Financial Operations & Expense Management — financial history is restricted
  # on delete (block, never silently orphan) to preserve the audit trail.
  has_many :expenses,            dependent: :restrict_with_error
  has_many :expense_allocations, dependent: :restrict_with_error
  has_many :recurring_expenses,  dependent: :restrict_with_error
  has_many :custody_accounts,    dependent: :restrict_with_error
  has_many :branch_revenues,     dependent: :restrict_with_error

  validates :name,     presence: true
  validates :business, presence: true
  validates :latitude, :longitude, :radius_meters,
            presence: true,
            if: :geolocation_enabled?
  validates :latitude,      numericality: { in: -90..90 },    allow_nil: true
  validates :longitude,     numericality: { in: -180..180 },  allow_nil: true
  validates :radius_meters, numericality: { greater_than: 0 }, allow_nil: true

  scope :active,        -> { where(active: true) }
  scope :for_business,  ->(business) { where(business: business) }
end
