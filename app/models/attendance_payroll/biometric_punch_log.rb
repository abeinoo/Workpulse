class BiometricPunchLog < ApplicationRecord
  ACTIONS = %w[
    check_in
    check_in_updated
    check_out
    rejected_no_assignment
    rejected_spam
    rejected_not_allowed
    rejected_stale_timestamp
    rejected_payroll_locked
    error
  ].freeze

  # Refusals that recorded nothing and must not make a later punch within the
  # spam window look like a duplicate (SEC-P12-1).
  NOT_SPAM_ACTIONS = %w[rejected_no_assignment rejected_stale_timestamp rejected_payroll_locked error].freeze

  SOURCES = %w[biometric mobile].freeze

  belongs_to :business
  belongs_to :biometric_device,  optional: true
  belongs_to :employee,          class_name: "User", optional: true
  belongs_to :attendance_record, optional: true

  validates :action,      inclusion: { in: ACTIONS }
  validates :source,      inclusion: { in: SOURCES }
  validates :punched_at,  presence: true
  validates :received_at, presence: true

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(received_at: :desc) }
  scope :for_employee, ->(user) { where(employee: user) }
  scope :from_source,  ->(src) { where(source: src) }

  def rejected?
    action.start_with?("rejected_")
  end

  def success?
    %w[check_in check_in_updated check_out].include?(action)
  end
end
