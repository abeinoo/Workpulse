class PayrollAdjustmentEdit < ApplicationRecord
  belongs_to :payroll_adjustment
  belongs_to :business
  belongs_to :edited_by, class_name: "User"

  validates :old_adjustment_type, :new_adjustment_type, presence: true
  validates :old_amount, :new_amount, numericality: { greater_than: 0 }
  validates :old_period_month, :new_period_month, presence: true, inclusion: { in: 1..12 }
  validates :old_period_year,  :new_period_year,  presence: true, numericality: { greater_than: 2000 }
end
