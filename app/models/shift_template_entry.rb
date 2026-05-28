class ShiftTemplateEntry < ApplicationRecord
  WEEKDAYS = (0..6).to_a.freeze

  belongs_to :shift_template
  belongs_to :shift
  belongs_to :branch,       optional: true
  belongs_to :rule_profile, class_name: "ShiftRuleProfile",
                            foreign_key: :shift_rule_profile_id, optional: true

  validates :starts_on, presence: true
  validates :shift_id,  presence: true

  # weekday is optional — used for display and future recurring scheduling
  validates :weekday, inclusion: { in: WEEKDAYS }, allow_nil: true

  # offset fields kept for future recurring scheduling (not used in date-based flow)
  validates :effective_from_offset,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true
  validates :effective_to_offset,
            numericality: { only_integer: true, greater_than: 0 },
            allow_nil: true

  validate :ends_on_after_starts_on
  validate :effective_to_offset_after_from_offset

  delegate :name, to: :shift,  prefix: true
  delegate :name, to: :branch, prefix: true, allow_nil: true

  # Returns the effective end date for assignment creation.
  # Falls back to starts_on if ends_on is nil (single-day coverage).
  def effective_ends_on
    ends_on || starts_on
  end

  # Returns the span in calendar days (inclusive).
  def day_span
    (effective_ends_on - starts_on).to_i + 1
  end

  def weekday_name
    weekday ? ShiftTemplate::WEEKDAY_NAMES[weekday] : nil
  end

  private

  def ends_on_after_starts_on
    return unless ends_on.present? && starts_on.present?
    errors.add(:ends_on, :must_be_on_or_after_starts_on) if ends_on < starts_on
  end

  def effective_to_offset_after_from_offset
    return unless effective_to_offset.present? && effective_from_offset.present?
    errors.add(:effective_to_offset, :must_be_after_from_offset) if effective_to_offset <= effective_from_offset
  end
end
