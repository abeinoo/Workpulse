class AddReviewDailyReconciliationPermission < ActiveRecord::Migration[8.1]
  # New "Branch Review" permissions are only auto-granted to existing
  # branch-manager-tier roles — matches DEFAULT_PERMISSIONS_BY_ROLE_TYPE.
  # override_review_requirement is intentionally never backfilled: it's a
  # blanket bypass, granted manually (owners already bypass all checks).
  def up
    PermissionRole.where(role_type: "branch_manager").find_each do |role|
      existing = Array(role.permissions)
      to_add = %w[view_daily_reconciliation review_daily_reconciliation] - existing
      next if to_add.empty?

      role.update_columns(permissions: existing + to_add)
      say "Added #{to_add.join(', ')} to '#{role.name}' (id=#{role.id})"
    end
  end

  def down
    removed = %w[review_daily_reconciliation]

    PermissionRole.find_each do |role|
      existing  = Array(role.permissions)
      to_remove = existing & removed
      next if to_remove.empty?

      role.update_columns(permissions: existing - to_remove)
    end
  end
end
