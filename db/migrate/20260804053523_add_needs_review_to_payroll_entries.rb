class AddNeedsReviewToPayrollEntries < ActiveRecord::Migration[8.1]
  def change
    # Lightweight visual flag: set automatically whenever the payroll-visible
    # result changes for this employee during an editable period, cleared by a
    # reviewer acknowledging the change. Not a workflow/approval state — the
    # existing branch-review sign-off is unaffected by this flag either way.
    add_column :payroll_entries, :needs_review, :boolean, default: false, null: false
  end
end
