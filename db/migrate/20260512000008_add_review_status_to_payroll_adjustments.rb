class AddReviewStatusToPayrollAdjustments < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_adjustments, :review_status, :string, null: false, default: "pending_review"
  end
end
