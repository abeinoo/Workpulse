# Additional consuming branches an employee may select on a Stock Issue or a
# Quick Issue, on top of their primary branch (Stock Issue & Quick Issue
# authorization, approved scope — not a general employee branch-access
# feature). Owned by Organization & Access (StockIssueBranchAssignment), changed
# only through OrganizationAccess::StockIssueBranchAccess (audited).
#
# History is kept in the table itself: a revocation sets revoked_at /
# revoked_by / revocation_reason and the row stays. At most one ACTIVE row per
# (user, branch) — enforced by the partial unique index. No backfill: nobody
# has an additional branch until one is granted explicitly.
class CreateStockIssueBranchAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_issue_branch_assignments do |t|
      t.references :business,   null: false, foreign_key: true
      t.references :user,       null: false, foreign_key: true
      t.references :branch,     null: false, foreign_key: true
      t.references :granted_by, null: false, foreign_key: { to_table: :users }
      t.datetime   :granted_at, null: false
      t.references :revoked_by, foreign_key: { to_table: :users }
      t.datetime   :revoked_at
      t.string     :revocation_reason
      t.timestamps
    end

    add_index :stock_issue_branch_assignments, %i[user_id branch_id], unique: true,
              where: "revoked_at IS NULL", name: "index_stock_issue_branch_assignments_active_unique"
    add_check_constraint :stock_issue_branch_assignments,
                         "(revoked_at IS NULL) = (revocation_reason IS NULL)",
                         name: "stock_issue_branch_assignments_revocation_complete"
    add_check_constraint :stock_issue_branch_assignments,
                         "revocation_reason IS NULL OR revocation_reason IN " \
                         "('revoked', 'branch_deactivated', 'branch_reclassified')",
                         name: "stock_issue_branch_assignments_revocation_reason"
  end
end
