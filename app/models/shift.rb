class Shift < ApplicationRecord
  belongs_to :business
  has_many :penalty_rules,     dependent: :destroy
  has_many :shift_assignments, dependent: :restrict_with_error

  accepts_nested_attributes_for :penalty_rules,
                                allow_destroy: true,
                                reject_if:     :all_blank

  SHIFT_TYPES = %w[fixed_time hour_based].freeze

  enum :shift_type, { fixed_time: "fixed_time", hour_based: "hour_based" }

  validates :name, :shift_type, :business, presence: true
  validates :name, uniqueness: { scope: :business_id }
  validates :start_time, :end_time, presence: true, if: :fixed_time?
  validates :required_hours,
            presence: true,
            numericality: { greater_than: 0 },
            if: :hour_based?
  validates :overtime_rate_multiplier,
            numericality: { greater_than_or_equal_to: 1 }, allow_nil: true

  scope :active,        -> { where(active: true) }
  scope :for_business,  ->(business) { where(business: business) }

  def overnight?
    fixed_time? && start_time && end_time && end_time < start_time
  end

  def duration_minutes
    return required_hours * 60 if hour_based?
    return unless start_time && end_time

    mins = ((end_time - start_time) / 60).to_i
    overnight? ? mins + (24 * 60) : mins
  end
end
