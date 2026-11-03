class BiometricPunchLog < ApplicationRecord
  ACTIONS = %w[
    check_in
    check_in_updated
    check_out
    recorded
    rejected_no_assignment
    rejected_spam
    rejected_not_allowed
    rejected_stale_timestamp
    rejected_payroll_locked
    rejected_branch_inactive
    error
  ].freeze

  # Refusals that recorded nothing and must not make a later punch within the
  # spam window look like a duplicate (SEC-P12-1).
  NOT_SPAM_ACTIONS = %w[
    rejected_no_assignment rejected_stale_timestamp rejected_payroll_locked rejected_branch_inactive error
  ].freeze

  # Device-punch actions that prove the employee was at the device that day, for
  # Attendance::AnomalyDetector's biometric_mismatch signal (TD-T-2; biometric
  # source only). Excluded: rejected_not_allowed, rejected_stale_timestamp
  # (untrusted timestamp) and error.
  BIOMETRIC_MISMATCH_EVIDENCE_ACTIONS = %w[
    check_in check_in_updated check_out recorded rejected_no_assignment rejected_spam rejected_payroll_locked
    rejected_branch_inactive
  ].freeze

  SOURCES = %w[biometric mobile].freeze

  belongs_to :business
  belongs_to :biometric_device,  optional: true
  belongs_to :employee,          class_name: "User", optional: true
  belongs_to :attendance_record, optional: true
  # The actual branch of the punch: its device's branch when the punch was
  # received (nil for a device with no branch, and for mobile punches). Not the
  # branch of the employee's shift assignment — that is the attendance record's.
  # Written once: reassigning the device never rewrites history.
  belongs_to :branch,            optional: true
  attr_readonly :branch_id

  validates :action,      inclusion: { in: ACTIONS }
  validates :source,      inclusion: { in: SOURCES }
  validates :punched_at,  presence: true
  validates :received_at, presence: true
  validate  :branch_in_same_business

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(received_at: :desc) }
  scope :for_employee, ->(user) { where(employee: user) }
  scope :from_source,  ->(src) { where(source: src) }

  def rejected?
    action.start_with?("rejected_")
  end

  def success?
    %w[check_in check_in_updated check_out recorded].include?(action)
  end

  private

  def branch_in_same_business
    errors.add(:branch, :other_business) if branch && branch.business_id != business_id
  end
end
