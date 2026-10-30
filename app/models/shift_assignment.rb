class ShiftAssignment < ApplicationRecord
  # How far ahead an assignment's end date may fall and still count as
  # "ending soon": drives the expiring-soon badges and which employees are
  # available for a new assignment (see Shifts::AssignmentEligibility).
  AVAILABILITY_WINDOW_DAYS = 7

  belongs_to :user
  belongs_to :shift
  belongs_to :branch
  belongs_to :rule_profile, class_name: "ShiftRuleProfile",
                            foreign_key: :shift_rule_profile_id, optional: true
  belongs_to :created_by,      class_name: "User",          optional: true
  belongs_to :ended_by,        class_name: "User",          optional: true
  belongs_to :source_template, class_name: "ShiftTemplate", optional: true

  # regular — the employee's normal, usually open-ended assignment.
  # temporary_coverage — a date-bounded assignment at a DIFFERENT branch that
  # temporarily supersedes the employee's regular branch for its window
  # (e.g. covering another branch's absence). Never mutates or replaces the
  # regular assignment row — see Shifts::AssignmentResolver, which prefers a
  # temporary_coverage assignment over a concurrent regular one when both are
  # active for the same date.
  enum :assignment_kind, { regular: "regular", temporary_coverage: "temporary_coverage" }

  validates :effective_from, presence: true
  validates :reason,       presence: true, if: :temporary_coverage?
  validates :effective_to, presence: true, if: :temporary_coverage?
  validate  :effective_to_after_effective_from
  validate  :no_overlapping_assignment
  validate  :no_overlapping_shift_time
  # A deactivated branch takes no new assignments and no assignment there is
  # reopened or extended into effect (BUG-026); existing ones keep their branch
  # and can still be ended or shortened.
  validate  :branch_active, if: -> { will_save_change_to_branch_id? || extends_into_effect? }
  # Backstop for every write path (web, API, template application, console):
  # the employee, shift and rule profile must belong to the business that owns
  # the branch (BUG-031) — attendance penalties and payroll read them.
  validate  :references_in_branch_business,
            if: -> { will_save_change_to_branch_id? || will_save_change_to_user_id? ||
                     will_save_change_to_shift_id? || will_save_change_to_shift_rule_profile_id? }

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

  # Distinct user_ids assigned to a single branch at any point during
  # [from, to] — the inverse of branch_ids_for_users, used for historical
  # branch-cost attribution (e.g. "who worked at the laundry this payroll
  # period"). No splitting/prorating: a user counts if they had any
  # overlapping assignment.
  def self.user_ids_for_branch_during(branch_id, from:, to:)
    active_during(from, to).where(branch_id: branch_id).distinct.pluck(:user_id)
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

  # Same as branch_names_by_user but keyed to branch_id — used where a system
  # process needs to attribute a business-wide cost (e.g. payroll-generated
  # expenses) back to the branch(es) it's actually associated with.
  def self.branch_ids_by_user(user_ids, from:, to:)
    active_during(from, to)
      .where(user_id: user_ids)
      .order(:effective_from)
      .pluck(:user_id, :branch_id)
      .each_with_object({}) { |(uid, branch_id), h| h[uid] = branch_id }
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

  # True when at least one attendance record was matched against this assignment.
  # Attendance belongs to Attendance & Payroll: the question is asked through the
  # Workforce contract Shifts::AttendanceUsage (F2), never by reading its tables.
  #
  # Fast path: when the index action SELECTs the contract's EXISTS expression as
  # `has_attendance` (to avoid N+1 queries), we read that preloaded value directly via
  # `self[:has_attendance]`. Slow path: any other context (form renders, API, specs)
  # fires one DB query per call and caches the result in an instance variable so
  # repeated calls in the same request don't pile up queries.
  def has_attendance_records?
    if has_attribute?(:has_attendance)
      ActiveModel::Type::Boolean.new.cast(self[:has_attendance])
    else
      @has_attendance_records_cache ||= Shifts::AttendanceUsage.recorded_against?(assignment_id: id)
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

  # True when the assignment ends within AVAILABILITY_WINDOW_DAYS (including today).
  def expiring_soon?
    days = days_until_expiry
    return false if days.nil?
    days.between?(0, AVAILABILITY_WINDOW_DAYS)
  end

  private

  # effective_to is inclusive (see .active_on/.active_during, both use >=), so
  # effective_from == effective_to is a valid single-day assignment — a
  # one-day temporary_coverage assignment (the most common real-world case:
  # "cover this one date") must be representable. Only a genuinely backwards
  # range (effective_to before effective_from) is rejected.
  def effective_to_after_effective_from
    return unless effective_to.present? && effective_from.present?

    errors.add(:effective_to, "must be on or after start date") if effective_to < effective_from
  end

  # Validations run inside save's transaction, so the shared branch lock is held
  # through the INSERT / UPDATE and its commit — a concurrent deactivation can
  # neither slip in between the check and the write nor miss the written row.
  def branch_active
    return if branch.nil?

    errors.add(:base, will_save_change_to_branch_id? ? :branch_inactive : :branch_inactive_reopen) unless Branch.active_under_share_lock?(branch_id)
  end

  def references_in_branch_business
    business_id = branch&.business_id
    return if business_id.nil?

    errors.add(:user_id, :other_business)               if user && user.business_id != business_id
    errors.add(:shift_id, :other_business)              if shift && shift.business_id != business_id
    errors.add(:shift_rule_profile_id, :other_business) if rule_profile && rule_profile.business_id != business_id
  end

  # An end date cleared, or moved later, so that the assignment is in effect on
  # or after the current business day. Ending, shortening, or correcting a date
  # that stays in the past is not.
  def extends_into_effect?
    return false unless persisted? && will_save_change_to_effective_to?

    previous = effective_to_in_database
    return false if previous.nil? # was open-ended: any end date ends or shortens it
    return true  if effective_to.nil?

    effective_to > previous && branch.present? && effective_to >= BusinessDay.current(context: branch.business)
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
  #
  # Exception: a temporary_coverage assignment is exempt from this check
  # against the SAME user's regular assignment(s) — coverage is meant to
  # temporarily supersede the regular assignment for its window ("instead
  # of", not "in addition to"), so a clashing clock-time is expected, not a
  # conflict. Two assignments of the SAME kind (regular-vs-regular,
  # temporary_coverage-vs-temporary_coverage) are still blocked exactly as
  # before — an employee still can't be double-booked at the same clock
  # hours in two regular shifts, or covering two branches at once.
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
      next if assignment_kind != other.assignment_kind
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
