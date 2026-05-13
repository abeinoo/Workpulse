class AddReviewerToPayrollAdjustments < ActiveRecord::Migration[8.0]
  def change
    add_reference :payroll_adjustments, :reviewed_by, foreign_key: { to_table: :users }, null: true
    add_column    :payroll_adjustments, :reviewed_at, :datetime
    add_column    :payroll_adjustments, :review_notes, :text
  end
end
