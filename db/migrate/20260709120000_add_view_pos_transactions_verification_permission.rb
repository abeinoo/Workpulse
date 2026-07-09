class AddViewPosTransactionsVerificationPermission < ActiveRecord::Migration[8.1]
  # manage_pos_import now depends on view_pos_transactions_verification (you
  # need to be able to see the verification data to manage its import).
  # Backfill any role that already has manage_pos_import so existing behavior
  # is preserved and the new PERMISSION_DEPENDENCIES entry stays satisfied.
  def up
    PermissionRole.find_each do |role|
      existing = Array(role.permissions)
      next unless existing.include?("manage_pos_import")
      next if existing.include?("view_pos_transactions_verification")

      role.update_columns(permissions: existing + %w[view_pos_transactions_verification])
      say "Added view_pos_transactions_verification to '#{role.name}' (id=#{role.id})"
    end
  end

  def down
    PermissionRole.find_each do |role|
      existing = Array(role.permissions)
      next unless existing.include?("view_pos_transactions_verification")

      role.update_columns(permissions: existing - %w[view_pos_transactions_verification])
    end
  end
end
