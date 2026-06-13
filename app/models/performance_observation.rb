class PerformanceObservation < ApplicationRecord
  belongs_to :business
  belongs_to :evaluation_criterion
  belongs_to :employee,    class_name: "User"
  belongs_to :observed_by, class_name: "User"

  TYPES = %w[positive negative neutral].freeze
  enum :observation_type,
       { positive: "positive", negative: "negative", neutral: "neutral" },
       prefix: :type

  validates :observation_date, presence: true
  validates :note, length: { maximum: 2000 }, allow_blank: true

  # A criterion must belong to the employee's department. Guarded so it only runs
  # when the employee or criterion is set/changed — editing the note or date on an
  # older record never re-triggers it, so pre-existing observations stay valid.
  validate :criterion_within_employee_department, if: :department_consistency_check_needed?

  scope :for_business, ->(business) { where(business: business) }
  scope :for_employee, ->(employee) { where(employee: employee) }
  scope :recent_first, -> { order(observation_date: :desc, created_at: :desc) }

  # Observations dated within a calendar month — the window a monthly review
  # pulls in. Uses observation_date (a date), so it's timezone-agnostic.
  scope :for_month, ->(year, month) {
    start_date = Date.new(year, month, 1)
    where(observation_date: start_date..start_date.end_of_month)
  }

  private

  def department_consistency_check_needed?
    new_record? ||
      will_save_change_to_employee_id? ||
      will_save_change_to_evaluation_criterion_id?
  end

  def criterion_within_employee_department
    return if employee.blank? || evaluation_criterion.blank?

    if employee.department_id.blank?
      errors.add(:employee, :without_department)
    elsif evaluation_criterion.evaluation_template&.department_id != employee.department_id
      errors.add(:evaluation_criterion_id, :department_mismatch)
    end
  end
end
