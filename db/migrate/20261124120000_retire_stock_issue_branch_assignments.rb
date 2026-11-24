# Retires the Stock Issue Branch Assignment feature (owner decision, Nov 24
# 2026): Stock Issues are authorized by warehouse access
# (Inventory::IssueWarehouseReach), so the per-employee "additional consuming
# branches" and the manage_branch_access permission no longer exist.
#
# 1. Drops stock_issue_branch_assignments (created by 20261124100000 — that
#    migration is left untouched). Dependencies checked: the table has only
#    OUTGOING foreign keys (businesses, users ×3, branches) — no table
#    references it — and no model, service or view reads it any more. Its
#    grant / revoke history stays in audit_logs (auditable_type
#    "StockIssueBranchAssignment"), which this migration does not touch.
# 2. Removes the retired "manage_branch_access" key from saved roles
#    (permission_roles.permissions / permission_scopes, jsonb) so no role keeps
#    a key the catalogue no longer accepts. Nothing else in a role changes.
#
# Stock Issues, stock movements, branches, users and audit logs are not touched.
# `down` recreates the empty table with its constraints; removed rows and the
# permission key are not restored.
class RetireStockIssueBranchAssignments < ActiveRecord::Migration[8.1]
  def up
    drop_table :stock_issue_branch_assignments

    execute <<~SQL
      UPDATE permission_roles
         SET permissions = permissions - 'manage_branch_access'
       WHERE permissions ? 'manage_branch_access'
    SQL
    execute <<~SQL
      UPDATE permission_roles
         SET permission_scopes = permission_scopes - 'manage_branch_access'
       WHERE permission_scopes ? 'manage_branch_access'
    SQL
  end

  def down
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
