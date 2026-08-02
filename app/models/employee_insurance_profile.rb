# The per-employee social insurance configuration. A single mutable record per
# user (unlike SalaryProfile's effective-dated history) — payroll protects
# historical accuracy by snapshotting these values onto PayrollEntry at
# generation time (see Payroll::EntryCalculator), so this record is free to be
# edited in place going forward without touching past payrolls.
class EmployeeInsuranceProfile < ApplicationRecord
  belongs_to :business
  belongs_to :user
  belongs_to :created_by, class_name: "User"

  validates :user_id, uniqueness: true
  validates :insurance_start_date, presence: true, if: :insured?
  validates :employee_contribution_amount, :employer_contribution_amount,
            numericality: { greater_than_or_equal_to: 0 }
  validate :end_date_after_start_date

  before_validation :zero_out_contributions_when_not_insured

  scope :for_business, ->(business) { where(business: business) }
  scope :insured,      -> { where(insured: true) }

  # Whether this profile's coverage window overlaps the given payroll period.
  def covers_period?(period_start, period_end)
    return false unless insured?
    return false if insurance_start_date.present? && insurance_start_date > period_end

    insurance_end_date.blank? || insurance_end_date >= period_start
  end

  private

  def zero_out_contributions_when_not_insured
    return if insured?

    self.employee_contribution_amount = 0
    self.employer_contribution_amount = 0
  end

  def end_date_after_start_date
    return if insurance_start_date.blank? || insurance_end_date.blank?

    errors.add(:insurance_end_date, "must be on or after the start date") if insurance_end_date < insurance_start_date
  end
end
