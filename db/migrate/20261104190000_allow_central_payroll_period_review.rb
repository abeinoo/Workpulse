# A payroll period's central review: one review slot with no branch, for the
# floating employees (no home branch) of the period, reviewed at business level
# instead of by a branch manager. Its reviewer is unknown until someone
# completes it, so reviewer_id may be NULL too (branch slots still carry their
# branch manager). A unique index on (payroll_period_id, branch_id) treats NULLs
# as distinct, so a partial unique index keeps it to one central slot per period.
#
# Rollback: restoring NOT NULL fails while any central slot exists. Those rows are
# review history (who signed the floating employees off, and when); roll back the
# code only and keep this migration, or export them first if a rollback is
# unavoidable.
class AllowCentralPayrollPeriodReview < ActiveRecord::Migration[8.1]
  def change
    change_column_null :payroll_period_branch_reviews, :branch_id, true
    change_column_null :payroll_period_branch_reviews, :reviewer_id, true
    add_index :payroll_period_branch_reviews, :payroll_period_id,
              unique: true, where: "branch_id IS NULL",
              name: "index_payroll_period_branch_reviews_one_central"
  end
end
