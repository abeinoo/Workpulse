class AddReviewFieldsToPayrollLineItems < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_line_items, :review_status, :string, null: false, default: "approved"
    add_reference :payroll_line_items, :reviewed_by, foreign_key: { to_table: :users }, null: true
    add_column :payroll_line_items, :reviewed_at, :datetime
    add_column :payroll_line_items, :review_notes, :text
    add_index :payroll_line_items, :review_status
  end
end
