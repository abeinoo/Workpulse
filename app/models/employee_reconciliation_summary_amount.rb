class EmployeeReconciliationSummaryAmount < ApplicationRecord
  belongs_to :employee_reconciliation_summary
  belongs_to :payment_method

  validates :payment_method_name, presence: true
  validates :collected_amount, numericality: true
  validates :refund_amount,    numericality: true

  def net_amount
    collected_amount - refund_amount
  end
end
