class PenaltyRule < ApplicationRecord
  belongs_to :shift

  RULE_TYPES       = %w[late_arrival early_leave].freeze
  DEDUCTION_TYPES  = %w[fixed_amount percentage_of_daily].freeze

  enum :rule_type,      { late_arrival: "late_arrival", early_leave: "early_leave" }
  enum :deduction_type, { fixed_amount: "fixed_amount", percentage_of_daily: "percentage_of_daily" }

  validates :rule_type, :deduction_type, presence: true
  validate :rule_type_compatible_with_shift
  validates :threshold_minutes, presence: true, numericality: { greater_than: 0 }
  validates :threshold_minutes, uniqueness: { scope: [ :shift_id, :rule_type ],
                                              message: "already has a rule at this threshold for this rule type" }
  validates :deduction_value,   presence: true, numericality: { greater_than: 0 }
  validates :deduction_value,
            numericality: { less_than_or_equal_to: 100 },
            if: :percentage_of_daily?

  scope :for_late_arrival,    -> { where(rule_type: "late_arrival") }
  scope :for_early_leave,     -> { where(rule_type: "early_leave") }
  scope :ordered_by_threshold, -> { order(threshold_minutes: :asc) }

  private

  def rule_type_compatible_with_shift
    return unless late_arrival? && shift&.hour_based?
    errors.add(:rule_type, :incompatible_with_hour_based)
  end

  public

  # Returns the highest-threshold rule that applies for a given minutes value.
  def self.applicable_for(minutes, rules_scope)
    rules_scope.ordered_by_threshold.select { |r| minutes >= r.threshold_minutes }.last
  end

  # Lowest threshold across the given rules (Array or relation), or nil when empty.
  # Operates in Ruby so it can run on eager-loaded associations without extra queries.
  def self.lowest_threshold(rules)
    rules.filter_map(&:threshold_minutes).min
  end
end
