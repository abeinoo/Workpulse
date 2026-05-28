class ShiftRuleProfile < ApplicationRecord
  belongs_to :business
  has_many :shift_assignments,    foreign_key: :shift_rule_profile_id, dependent: :nullify
  has_many :shift_template_entries, foreign_key: :shift_rule_profile_id, dependent: :nullify

  validates :name, presence: true,
                   uniqueness: { scope: :business_id, case_sensitive: false }
  validates :business_id, presence: true

  validates :expected_work_hours,
            numericality: { greater_than: 0 },
            allow_nil: true

  validates :break_minutes,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true

  validates :late_grace_minutes,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true

  validates :early_leave_grace_minutes,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true

  validates :overtime_multiplier,
            numericality: { greater_than_or_equal_to: 1 },
            allow_nil: true

  scope :active,        -> { where(active: true) }
  scope :for_business,  ->(business) { where(business_id: business.id) }

  # Returns effective late grace in minutes (0 if not set).
  def effective_late_grace
    late_grace_minutes.to_i
  end

  # Returns effective early-leave grace in minutes (0 if not set).
  def effective_early_leave_grace
    early_leave_grace_minutes.to_i
  end

  # Returns effective break minutes (0 if not set).
  def effective_break_minutes
    break_minutes.to_i
  end

  def overtime_enabled?
    overtime_enabled
  end
end
