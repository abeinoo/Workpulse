# Stock Issue — warehouse-based authorization: an import is made for a
# warehouse the user may use, not for a consuming branch. The batch's
# branch_id now only mirrors its StockIssue's cost-attribution branch, which
# is nil for a central (non-branch) warehouse, so the column must accept NULL.
#
# Non-destructive: no row is changed (every existing batch keeps its branch);
# only the NOT NULL constraint is dropped. `down` restores it and fails, by
# design, if a batch without a branch exists by then.
class AllowNullBranchOnStockIssueImportBatches < ActiveRecord::Migration[8.1]
  def change
    change_column_null :stock_issue_import_batches, :branch_id, true
  end
end
