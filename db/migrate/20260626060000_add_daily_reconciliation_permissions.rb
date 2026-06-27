class AddDailyReconciliationPermissions < ActiveRecord::Migration[8.1]
  # New permissions added in the Daily Reconciliation permission group.
  # Each entry maps: new_permission => [existing_permissions that qualify a role to receive it]
  NEW_PERMISSIONS = {
    "create_till_session"  => %w[close_till_session create_shift_closing],
    "view_session_totals"  => %w[view_daily_reconciliation],
    "edit_session_totals"  => %w[verify_daily_reconciliation],
    "void_till_handover"   => %w[verify_daily_reconciliation]
  }.freeze

  def up
    PermissionRole.find_each do |role|
      existing = Array(role.permissions)
      to_add = []

      NEW_PERMISSIONS.each do |new_perm, qualifiers|
        next if existing.include?(new_perm)
        to_add << new_perm if (existing & qualifiers).any?
      end

      next if to_add.empty?

      role.update_columns(permissions: existing + to_add)
      say "Added #{to_add.join(', ')} to '#{role.name}' (id=#{role.id})"
    end
  end

  def down
    new_perms = NEW_PERMISSIONS.keys

    PermissionRole.find_each do |role|
      existing = Array(role.permissions)
      to_remove = existing & new_perms
      next if to_remove.empty?

      role.update_columns(permissions: existing - to_remove)
    end
  end
end
