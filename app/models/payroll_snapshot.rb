class PayrollSnapshot < ApplicationRecord
  belongs_to :payroll_period
  belongs_to :taken_by, class_name: "User"

  TRIGGERS = %w[pre_regenerate manual].freeze

  validates :trigger, inclusion: { in: TRIGGERS }
  validates :employee_count, numericality: { greater_than_or_equal_to: 0 }

  # Returns a hash of numeric deltas: positive means current is higher.
  def diff_from(other)
    {
      net:        total_net        - other.total_net,
      base:       total_base       - other.total_base,
      overtime:   total_overtime   - other.total_overtime,
      deductions: total_deductions - other.total_deductions,
      bonuses:    total_bonuses    - other.total_bonuses,
      employees:  employee_count   - other.employee_count,
    }
  end

  # Per-employee net change keyed by user_id. Returns {} when no previous data.
  def employee_net_changes_from(other)
    prev_by_user = other.employee_details.index_by { |e| e["user_id"] }
    employee_details.each_with_object({}) do |e, h|
      prev = prev_by_user[e["user_id"]]
      h[e["user_id"]] = prev ? (e["net"].to_f - prev["net"].to_f) : nil
    end
  end
end
