class RemoveManagePosTerminalsPermission < ActiveRecord::Migration[8.1]
  # The standalone Terminal configuration page/permission is retired — Terminal
  # IDs are now managed as a nested section of the Branch form, gated by the
  # existing manage_branches permission. Strips the now-meaningless
  # manage_pos_terminals string from any role that had it, preserving
  # everything else on the role untouched.
  PERMISSION = "manage_pos_terminals".freeze

  def up
    strip_permission
  end

  def down
    # Not restorable to its original scope value (that information isn't kept)
    # — re-adding the permission itself is enough to make the role functional
    # again if this migration is ever rolled back.
    PermissionRole.reset_column_information

    PermissionRole.find_each do |role|
      permissions = Array(role.permissions)
      next if permissions.include?(PERMISSION)

      role.update_columns(permissions: permissions + [ PERMISSION ])
    end
  end

  private

  def strip_permission
    PermissionRole.reset_column_information

    PermissionRole.find_each do |role|
      permissions = Array(role.permissions)
      scopes      = (role.permission_scopes || {}).dup
      changed     = false

      if permissions.include?(PERMISSION)
        permissions = permissions - [ PERMISSION ]
        changed = true
      end

      if scopes.key?(PERMISSION)
        scopes.delete(PERMISSION)
        changed = true
      end

      next unless changed

      role.update_columns(permissions: permissions, permission_scopes: scopes)
      say "Removed manage_pos_terminals from '#{role.name}' (id=#{role.id})"
    end
  end
end
