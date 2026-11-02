class SalaryProfile < ApplicationRecord
  belongs_to :user

  SALARY_TYPES = %w[monthly daily].freeze

  enum :salary_type, { monthly: "monthly", daily: "daily" }

  validates :salary_type,         presence: true, inclusion: { in: SALARY_TYPES }
  validates :base_amount,         presence: true, numericality: { greater_than: 0 }
  validates :overtime_multiplier, numericality: { greater_than: 0, less_than_or_equal_to: 5 },
                                  allow_nil: true
  validates :currency,            presence: true
  validates :effective_from,      presence: true

  # Superseded profiles are immutable: only the latest entered (`active`) or the
  # one in force today may be corrected in place — while a later-dated change is
  # scheduled, the profile in force is no longer `active` but stays correctable.
  validate :immutable_if_historical, on: :update
  # A correction never moves a profile onto or past the next later-dated profile,
  # so the order in which profiles take effect is never rewritten.
  validate :effective_from_before_next_profile, on: :update, if: :effective_from_changed?

  # Deactivate any existing active profiles before inserting a new one,
  # ensuring only one active profile per user at any time. `active` marks the
  # most recently entered profile, NOT the salary in force: a profile entered
  # with a future effective_from is active at once but takes effect only on
  # that date.
  before_create :deactivate_previous_active_profiles

  scope :active,       -> { where(active: true) }
  scope :for_business, ->(business) { joins(:user).where(users: { business_id: business.id }) }

  # The effective salary — the single definition shared by salary display, the
  # advance limit and payroll (Salary::DailyRateCalculator): the employee's
  # profile with the latest effective_from on or before `date`; on a tie, the
  # most recently entered. Superseded and future-dated profiles stay stored.
  EFFECTIVE_ORDER = { effective_from: :desc, id: :desc }.freeze

  # Each employee's effective profile on `date` (one row per employee).
  scope :effective_on, lambda { |date|
    where(id: SalaryProfile.unscoped
                           .select("DISTINCT ON (salary_profiles.user_id) salary_profiles.id")
                           .where(effective_from: ..date)
                           .order(:user_id, EFFECTIVE_ORDER))
  }

  def self.effective_for(user, date:)
    user.salary_profiles.where(effective_from: ..date).order(EFFECTIVE_ORDER).first
  end

  # "Today" for salary purposes: the business day (BusinessDay — timezone and
  # day-start hour), the same calendar attendance work dates and payroll use.
  def self.effective_date_for(business)
    BusinessDay.current(context: business)
  end

  # The salary in force today, or nil.
  def self.current_for(user)
    effective_for(user, date: effective_date_for(user.business))
  end

  def effective?(date = self.class.effective_date_for(user.business))
    self.class.effective_for(user, date: date) == self
  end

  private

  def deactivate_previous_active_profiles
    user.salary_profiles.where(active: true).update_all(active: false)
  end

  # active_in_database reflects the persisted value before this update began.
  # If it is already false and the profile is not the one in force today (read
  # from the persisted rows), it is historical and must not change.
  def immutable_if_historical
    return if active_in_database
    return if self.class.effective_for(user, date: self.class.effective_date_for(user.business))&.id == id

    errors.add(:base, "Historical salary profiles cannot be modified")
  end

  def effective_from_before_next_profile
    return if effective_from.blank?

    next_date = user.salary_profiles.where.not(id: id).where("effective_from > ?", effective_from_in_database)
                    .minimum(:effective_from)
    return if next_date.nil? || effective_from < next_date

    errors.add(:effective_from, :must_precede_next_profile, date: I18n.l(next_date))
  end
end
