class ShiftAssignment < ApplicationRecord
  belongs_to :user
  belongs_to :shift
  belongs_to :branch, optional: true

  validates :effective_from, presence: true
  validate  :effective_to_after_effective_from
  validate  :no_overlapping_assignment
  validate  :no_overlapping_shift_time

  scope :active_on, ->(date) {
    where("effective_from <= ?", date)
      .where("effective_to IS NULL OR effective_to >= ?", date)
  }
  scope :current, -> { active_on(Date.current) }
  scope :for_business, ->(business) {
    joins(:user).where(users: { business_id: business.id })
  }

  delegate :name, to: :shift,  prefix: true
  delegate :name, to: :branch, prefix: true, allow_nil: true

  private

  def effective_to_after_effective_from
    return unless effective_to.present? && effective_from.present?

    errors.add(:effective_to, "must be after start date") if effective_to <= effective_from
  end

  def no_overlapping_assignment
    return unless user_id && effective_from

    range_end  = effective_to || Date.new(9999, 12, 31)
    base_scope = ShiftAssignment.where(user_id: user_id).where.not(id: id)
    base_scope = branch_id ? base_scope.where(branch_id: branch_id)
                           : base_scope.where(branch_id: nil)

    overlap = base_scope
      .where("effective_from <= ?", range_end)
      .where("effective_to IS NULL OR effective_to >= ?", effective_from)
      .exists?

    msg = branch_id ? "Overlaps with an existing assignment for this user in this branch"
                    : "Overlaps with an existing unassigned shift for this user"
    errors.add(:base, msg) if overlap
  end

  # Prevents assigning two fixed-time shifts whose clock hours overlap on any
  # concurrent day — regardless of branch. Only applies when both shifts are
  # fixed_time (hour_based shifts have no defined start/end time so cannot be
  # checked). Handles overnight shifts crossing midnight.
  def no_overlapping_shift_time
    return unless user_id && effective_from && shift_id
    return unless shift&.fixed_time?

    range_end  = effective_to || Date.new(9999, 12, 31)
    concurrent = ShiftAssignment
      .includes(:shift)
      .where(user_id: user_id)
      .where.not(id: id)
      .where("effective_from <= ?", range_end)
      .where("effective_to IS NULL OR effective_to >= ?", effective_from)

    concurrent.each do |other|
      next unless other.shift&.fixed_time?
      next unless shift_times_overlap?(shift, other.shift)

      errors.add(:base, I18n.t("shift_assignments.errors.overlapping_time",
                               shift_name: other.shift.name,
                               start_time: other.shift.start_time.strftime("%H:%M"),
                               end_time:   other.shift.end_time.strftime("%H:%M")))
      return
    end
  end

  # Returns true when two fixed-time shifts share any overlapping minutes.
  # Works for overnight shifts (end_time < start_time) by normalising into a
  # 48-hour window and testing three offset positions.
  def shift_times_overlap?(s1, s2)
    sa = s1.start_time.hour * 60 + s1.start_time.min
    ea = s1.end_time.hour   * 60 + s1.end_time.min
    sb = s2.start_time.hour * 60 + s2.start_time.min
    eb = s2.end_time.hour   * 60 + s2.end_time.min

    ea += 1440 if ea <= sa  # overnight shift A: push end past midnight
    eb += 1440 if eb <= sb  # overnight shift B: push end past midnight

    # Three windows cover every midnight-crossing combination:
    #   1. both shifts on the same day
    #   2. shift B one day later (B is overnight, overlaps next morning of A)
    #   3. shift A one day later (A is overnight, overlaps next morning of B)
    intervals_overlap?(sa, ea, sb,        eb)        ||
      intervals_overlap?(sa, ea, sb + 1440, eb + 1440) ||
      intervals_overlap?(sa + 1440, ea + 1440, sb, eb)
  end

  def intervals_overlap?(s1, e1, s2, e2)
    [s1, s2].max < [e1, e2].min
  end
end
