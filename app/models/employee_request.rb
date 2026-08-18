class EmployeeRequest < ApplicationRecord
  belongs_to :user
  belongs_to :reviewed_by,   class_name: "User", optional: true
  belongs_to :cancelled_by,  class_name: "User", optional: true
  has_one    :advance, dependent: :destroy

  REQUEST_TYPES    = %w[salary_advance late_permission early_leave punch_correction].freeze
  CORRECTION_TYPES = %w[missing_check_in missing_check_out wrong_check_in_time wrong_check_out_time].freeze
  STATUSES         = %w[pending approved rejected paid cancelled].freeze

  enum :request_type, { salary_advance: "salary_advance", late_permission: "late_permission",
                        early_leave: "early_leave", punch_correction: "punch_correction" }
  # salary advances:    pending → approved (manager) → paid (accountant/admin, creates Advance)
  # other types:        pending → approved | rejected
  # any cancellable:    pending | approved → cancelled
  enum :status, { pending: "pending", approved: "approved", rejected: "rejected",
                  paid: "paid", cancelled: "cancelled" }
  enum :correction_type, { missing_check_in: "missing_check_in", missing_check_out: "missing_check_out",
                            wrong_check_in_time: "wrong_check_in_time",
                            wrong_check_out_time: "wrong_check_out_time" }, prefix: :correction

  validates :request_type, :requested_for_date, :reason, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }, if: :salary_advance?
  validate :within_advance_limit, on: :create, if: :salary_advance?
  validates :duration_minutes,
            presence: true,
            on: :create,
            if: -> { late_permission? || early_leave? }
  validates :duration_minutes,
            numericality: { only_integer: true, greater_than: 0 },
            allow_nil: true
  validate :within_monthly_permission_limit, on: :create,
           if: -> { late_permission? || early_leave? }
  validate :shift_supports_request_type, if: :late_permission?, on: :create
  validates :correction_type, presence: true, if: :punch_correction?
  validates :proposed_time,   presence: true, if: :punch_correction?
  validates :proposed_date,   presence: true, if: :punch_correction?

  before_validation :default_proposed_date, if: :punch_correction?
  before_save :derive_affects_payroll

  # Review-queue display priority: pending first, then approved, then rejected,
  # then any remaining status (e.g. paid). Drives the default index ordering so
  # managers always see actionable (pending) requests at the top.
  REVIEW_PRIORITY = %w[pending approved rejected].freeze

  # Business scoping through user, not branch.
  scope :for_business, ->(business) {
    joins(:user).where(users: { business_id: business.id })
  }

  # Default index order, computed entirely in the database: status priority
  # (pending → approved → rejected → other), then newest-first within each group.
  scope :sorted_for_review, -> {
    order(Arel.sql(review_priority_case)).order(created_at: :desc)
  }

  # Priority ordering for the UI index:
  #   1 – Pending (actionable for managers)
  #   2 – Approved salary advances awaiting disbursement (actionable for accountants)
  #   3 – Paid / other approved requests (completed)
  #   4 – Rejected
  #   5 – Everything else (cancelled, etc.)
  # Requires a LEFT JOIN on advances so we can distinguish "approved + no advance"
  # (awaiting payment) from "approved + advance exists" (already disbursed).
  scope :priority_order, -> {
    left_joins(:advance)
      .order(Arel.sql(priority_case_sql))
      .order(created_at: :desc)
  }

  def self.priority_case_sql
    <<~SQL.squish
      CASE
        WHEN employee_requests.status = 'pending' THEN 1
        WHEN employee_requests.status = 'approved'
             AND employee_requests.request_type = 'salary_advance'
             AND advances.id IS NULL THEN 2
        WHEN employee_requests.status IN ('paid', 'approved') THEN 3
        WHEN employee_requests.status = 'rejected' THEN 4
        ELSE 5
      END
    SQL
  end

  # ── Index filters (all no-op when the value is blank, so they compose freely) ──
  scope :with_status, ->(status)  { where(status: status) if status.present? }
  scope :for_user,    ->(user_id) { where(user_id: user_id) if user_id.present? }
  # Branch membership is shift-driven: an employee belongs to a branch while they
  # hold an active ShiftAssignment to it.
  scope :for_branch,  ->(branch_id) {
    where(user_id: ShiftAssignment.user_ids_for_branches([ branch_id ])) if branch_id.present?
  }
  scope :with_request_type,       ->(type) { where(request_type: type) if type.present? }
  scope :requested_on_or_after,  ->(date) { where(requested_for_date: date..) if date.present? }
  scope :requested_on_or_before, ->(date) { where(requested_for_date: ..date) if date.present? }

  # Builds the SQL CASE expression that maps each status to its review-priority
  # rank. Values come from the REVIEW_PRIORITY constant and are quoted through the
  # connection, so the fragment is safe to wrap in Arel.sql.
  def self.review_priority_case
    whens = REVIEW_PRIORITY.each_with_index.map do |status, rank|
      "WHEN #{connection.quote(status)} THEN #{rank}"
    end.join(" ")
    "CASE employee_requests.status #{whens} ELSE #{REVIEW_PRIORITY.size} END"
  end

  # Finds pending requests from employees currently assigned (active ShiftAssignment)
  # to any of the given branches. Branch membership is shift-driven.
  scope :pending_for_branch, ->(branch_ids) {
    where(status: "pending", user_id: ShiftAssignment.user_ids_for_branches(branch_ids))
      .distinct
  }

  # Returns the number of approved permission minutes for a user on a given date.
  # Zero means no exemption applies. Used by EntryCalculator for partial reduction.
  def self.approved_minutes(user:, date:, type:)
    request = where(
      user:               user,
      requested_for_date: date,
      request_type:       type,
      status:             "approved",
      affects_payroll:    true
    ).first
    request&.duration_minutes.to_i
  end

  private

  # For same-day (non-overnight) corrections the punch date equals the work date,
  # so we default it to avoid forcing employees to re-enter it. Overnight shifts
  # (e.g. a check-out after midnight) must set proposed_date explicitly.
  def default_proposed_date
    self.proposed_date ||= requested_for_date
  end

  # affects_payroll drives EntryCalculator exemptions; only duration-based types apply.
  def derive_affects_payroll
    self.affects_payroll = late_permission? || early_leave?
  end

  def within_advance_limit
    return unless amount.present? && user.present?

    result = Salary::AdvanceEligibilityCalculator.for(user: user)
    return unless result  # no limit configured — unrestricted

    if result.no_profile?
      errors.add(:amount, I18n.t("requests.errors.no_salary_profile"))
      return
    end

    if amount.to_f > result.available
      errors.add(:amount,
                 I18n.t("requests.errors.exceeds_advance_limit",
                        available: result.available,
                        currency:  user.business.currency))
    end
  end

  def shift_supports_request_type
    return unless user.present? && requested_for_date.present?

    assignment = ShiftAssignment.active_on(requested_for_date).find_by(user: user)
    return unless assignment&.shift&.hour_based?

    errors.add(:request_type, I18n.t("requests.errors.unavailable_for_hour_based"))
  end

  def within_monthly_permission_limit
    return unless duration_minutes.present? && requested_for_date.present? && user.present?

    limit = permission_limit
    return unless limit.present?

    month_start = requested_for_date.beginning_of_month
    month_end   = requested_for_date.end_of_month

    used = self.class
               .where(user: user, request_type: request_type, status: %w[pending approved])
               .where(requested_for_date: month_start..month_end)
               .sum(:duration_minutes)

    remaining = [ limit - used, 0 ].max
    if duration_minutes > remaining
      errors.add(:duration_minutes,
                 I18n.t("requests.errors.exceeds_monthly_limit",
                        remaining: remaining, limit: limit))
    end
  end

  # Reads the monthly permission limit from the employee's active shift on the
  # requested date. Falls back to the business-level setting for shifts that
  # predate the per-shift configuration (i.e. still have nil values).
  def permission_limit
    shift = ShiftAssignment.active_on(requested_for_date).find_by(user: user)&.shift
    if late_permission?
      shift&.max_late_permission_minutes || user.business.max_late_permission_minutes
    elsif early_leave?
      shift&.max_early_leave_permission_minutes || user.business.max_early_leave_permission_minutes
    end
  end
end
