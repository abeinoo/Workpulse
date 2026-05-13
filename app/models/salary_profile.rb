class SalaryProfile < ApplicationRecord
  belongs_to :user

  SALARY_TYPES = %w[monthly daily].freeze

  enum :salary_type, { monthly: "monthly", daily: "daily" }

  attribute :overtime_multiplier, :decimal, default: 1.5

  validates :salary_type,         presence: true, inclusion: { in: SALARY_TYPES }
  validates :base_amount,         presence: true, numericality: { greater_than: 0 }
  validates :overtime_multiplier, presence: true,
                                  numericality: { greater_than: 0, less_than_or_equal_to: 5 }
  validates :currency,            presence: true
  validates :effective_from,      presence: true

  # Historical profiles (active: false) are immutable once superseded.
  validate :immutable_if_historical, on: :update

  # Deactivate any existing active profiles before inserting a new one,
  # ensuring only one active profile per user at any time.
  before_create :deactivate_previous_active_profiles

  scope :active,       -> { where(active: true) }
  scope :for_business, ->(business) { joins(:user).where(users: { business_id: business.id }) }

  def self.current_for(user)
    where(user: user, active: true)
      .where("effective_from <= ?", Date.current)
      .order(effective_from: :desc)
      .first
  end

  private

  def deactivate_previous_active_profiles
    user.salary_profiles.where(active: true).update_all(active: false)
  end

  # active_in_database reflects the persisted value before this update began.
  # If it is already false the profile is historical and must not change.
  def immutable_if_historical
    errors.add(:base, "Historical salary profiles cannot be modified") unless active_in_database
  end
end
