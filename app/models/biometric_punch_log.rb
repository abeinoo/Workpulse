class BiometricPunchLog < ApplicationRecord
  ACTIONS = %w[
    check_in
    check_in_updated
    check_out
    rejected_no_assignment
    rejected_spam
    error
  ].freeze

  belongs_to :business
  belongs_to :biometric_device,  optional: true
  belongs_to :employee,          class_name: "User", optional: true
  belongs_to :attendance_record, optional: true

  validates :action,      inclusion: { in: ACTIONS }
  validates :punched_at,  presence: true
  validates :received_at, presence: true

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(received_at: :desc) }
  scope :for_employee, ->(user) { where(employee: user) }

  def rejected?
    action.start_with?("rejected_")
  end

  def success?
    %w[check_in check_in_updated check_out].include?(action)
  end
end
