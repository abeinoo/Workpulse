class EmployeeReconciliationSummary < ApplicationRecord
  belongs_to :daily_reconciliation
  belongs_to :user

  has_many :amounts,
           class_name:  "EmployeeReconciliationSummaryAmount",
           dependent:   :destroy

  validates :computed_at, presence: true

  def grand_total
    amounts.sum(&:net_amount)
  end
end
