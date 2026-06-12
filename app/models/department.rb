class Department < ApplicationRecord
  belongs_to :business

  # Employees link via the additive users.department_id. nullify (not destroy)
  # keeps employees intact if a department is ever hard-deleted; the normal
  # lifecycle is soft-delete via #active.
  has_many :users, dependent: :nullify

  # restrict_with_error protects historical performance data: a department that
  # owns templates or reviews can't be destroyed — deactivate it instead.
  has_many :evaluation_templates, dependent: :restrict_with_error
  has_many :performance_reviews,  dependent: :restrict_with_error

  # Trim + collapse internal whitespace before validation so "  Reception  Desk"
  # and "Reception Desk" never become distinct rows. Mirrors the backfill rules.
  normalizes :name, with: ->(v) { v.to_s.strip.gsub(/\s+/, " ").presence }

  validates :name, presence: true,
                   length: { maximum: 100 },
                   uniqueness: { scope: :business_id, case_sensitive: false }

  scope :active,  -> { where(active: true) }
  scope :ordered, -> { order(:name) }
  scope :for_business, ->(business) { where(business: business) }

  def deactivate! = update!(active: false)
  def activate!   = update!(active: true)
end
