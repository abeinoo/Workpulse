class EmployeeRequest < ApplicationRecord
  belongs_to :user
  belongs_to :reviewed_by, class_name: "User", optional: true
  has_one    :advance, dependent: :destroy

  REQUEST_TYPES    = %w[salary_advance late_permission early_leave punch_correction].freeze
  CORRECTION_TYPES = %w[missing_check_in missing_check_out wrong_check_in_time wrong_check_out_time].freeze
  STATUSES         = %w[pending approved rejected paid].freeze

  enum :request_type, { salary_advance: "salary_advance", late_permission: "late_permission",
                        early_leave: "early_leave", punch_correction: "punch_correction" }
  # salary advances:    pending → approved (manager) → paid (accountant/admin, creates Advance)
  # other types:        pending → approved | rejected
  enum :status, { pending: "pending", approved: "approved", rejected: "rejected", paid: "paid" }
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

  before_save :derive_affects_payroll

  # Business scoping through user, not branch.
  scope :for_business, ->(business) {
    joins(:user).where(users: { business_id: business.id })
  }

  # Finds pending requests from employees who belong to any of the given branches.
  scope :pending_for_branch, ->(branch_ids) {
    joins(user: :user_branches)
      .where(user_branches: { branch_id: branch_ids }, status: "pending")
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

  # affects_payroll drives EntryCalculator exemptions; only duration-based types apply.
  def derive_affects_payroll
    self.affects_payroll = late_permission? || early_leave?
  end

  def within_advance_limit
    return unless amount.present? && user.present?

    result = Salary::AdvanceEligibilityCalculator.for(user: user)
    return unless result  # no limit configured — unrestricted

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
