class ShiftAssignment < ApplicationRecord
  belongs_to :user
  belongs_to :shift
  belongs_to :branch
  belongs_to :rule_profile, class_name: "ShiftRuleProfile",
                            foreign_key: :shift_rule_profile_id, optional: true
  belongs_to :created_by,      class_name: "User",          optional: true
  belongs_to :ended_by,        class_name: "User",          optional: true
  belongs_to :source_template, class_name: "ShiftTemplate", optional: true

  validates :effective_from, presence: true
  validate  :effective_to_after_effective_from
  validate  :no_overlapping_assignment
  validate  :no_overlapping_shift_time

  # ── Scopes ──────────────────────────────────────────────────────────────────

  scope :active_on, ->(date) {
    where("effective_from <= ?", date)
      .where("effective_to IS NULL OR effective_to >= ?", date)
  }
  # Assignments overlapping a date range [from, to] (period-based branch attribution).
  scope :active_during, ->(from, to) {
    where("effective_from <= ?", to)
      .where("effective_to IS NULL OR effective_to >= ?", from)
  }
  scope :current,  -> { active_on(Date.current) }
  scope :upcoming, -> { where("effective_from > ?", Date.current) }
  scope :expired,  -> {
    where("effective_to IS NOT NULL AND effective_to < ?", Date.current)
  }
  scope :for_business,     ->(business) {
    joins(:user).where(users: { business_id: business.id })
  }
  scope :from_template,    -> { where.not(source_template_id: nil) }
  scope :manual,           -> { where(source_template_id: nil) }
  scope :for_template,     ->(id) { where(source_template_id: id) }

  delegate :name, to: :shift,  prefix: true
  delegate :name, to: :branch, prefix: true, allow_nil: true

  # ── Branch membership resolution ─────────────────────────────────────────────
  # ShiftAssignment is the authoritative source of an employee's branch. These
  # helpers replace the legacy UserBranch join table for payroll attribution and
  # the Branch Only employee scope.

  # Chainable subquery of user_ids assigned to any of `branch_ids`, active on `on`.
  def self.user_ids_for_branches(branch_ids, on: Date.current)
    active_on(on).where(branch_id: branch_ids).select(:user_id)
  end

  # Distinct branch_ids the given users were assigned to during [from, to].
  def self.branch_ids_for_users(user_ids, from:, to:)
    active_during(from, to).where(user_id: user_ids).distinct.pluck(:branch_id)
  end

  # Map of user_id => branch name for the given users, using assignments active
  # during [from, to]. When a user worked multiple branches, the latest-effective
  # assignment wins.
  def self.branch_names_by_user(user_ids, from:, to:)
    active_during(from, to)
      .where(user_id: user_ids)
      .joins(:branch)
      .order(:effective_from)
      .pluck(:user_id, "branches.name")
      .each_with_object({}) { |(uid, name), h| h[uid] = name }
  end

  # ── Status helpers ───────────────────────────────────────────────────────────

  # Assignment starts in the future (before today — no punches yet).
  def future?
    effective_from > Date.current
  end

  # Assignment is currently active (covers today).
  def current?
    effective_from <= Date.current &&
      (effective_to.nil? || effective_to >= Date.current)
  end

  # Assignment has fully ended (effective_to is in the past).
  def historical?
    effective_to.present? && effective_to < Date.current
  end

  # True when at least one AttendanceRecord was matched against this assignment.
  #
  # Fast path: when the index action SELECTs the EXISTS subquery as `has_attendance`
  # (to avoid N+1 queries), we read that preloaded value directly via `self[:has_attendance]`.
  # Slow path: any other context (form renders, API, specs) fires one DB query per call
  # and caches the result in an instance variable so repeated calls in the same request
  # don't pile up queries.
  def has_attendance_records?
    if has_attribute?(:has_attendance)
      ActiveModel::Type::Boolean.new.cast(self[:has_attendance])
    else
      @has_attendance_records_cache ||= AttendanceRecord.where(shift_assignment_id: id).exists?
    end
  end

  # An assignment is deletable (hard-delete) only when no attendance record
  # references it — this preserves the shift→attendance FK integrity.
  def deletable?
    !has_attendance_records?
  end

  def template_sourced?
    source_template_id.present?
  end

  # An assignment is temporary when it has a defined end date (date-bounded)
  # or was generated from a scheduling template (structured, not ad-hoc).
  # Open-ended manual assignments are considered permanent.
  def temporary?
    effective_to.present? || source_template_id.present?
  end

  def active_temporary?
    temporary? && current?
  end

  def expired_temporary?
    temporary? && historical?
  end

  # Days remaining until effective_to. Negative means already passed.
  # Returns nil when the assignment has no end date.
  def days_until_expiry
    return nil unless effective_to.present?
    (effective_to - Date.current).to_i
  end

  # True when the assignment ends within 7 days (including today).
  def expiring_soon?
    days = days_until_expiry
    return false if days.nil?
    days.between?(0, 7)
  end

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

    overlapping = base_scope
      .where("effective_from <= ?", range_end)
      .where("effective_to IS NULL OR effective_to >= ?", effective_from)
      .exists?

    return unless overlapping

    if branch_id
      errors.add(:base, I18n.t("shift_assignments.errors.overlapping_branch"))
    else
      errors.add(:base, I18n.t("shift_assignments.errors.overlapping_unassigned"))
    end
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
    [ s1, s2 ].max < [ e1, e2 ].min
  end
end
