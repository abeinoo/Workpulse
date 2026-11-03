# Set on the entries whose figures a Recalculate Payroll run changed
# (Payroll::PeriodRecalculator). Unlike the lightweight needs_review flag, it
# blocks finalization until a reviewer acknowledges the new figures (Mark
# Reviewed — Payroll::EntryReviewClearer), so a sign-off given before the
# recalculation is never taken as approval of the recalculated figures.
class AddRecalculationReviewRequiredToPayrollEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_entries, :recalculation_review_required, :boolean, default: false, null: false
  end
end
