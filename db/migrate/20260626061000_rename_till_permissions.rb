class RenameTillPermissions < ActiveRecord::Migration[8.1]
  RENAMES = {
    "create_shift_closing"  => "close_till_session",
    "accept_shift_handover" => "accept_till_handover"
  }.freeze

  def up
    PermissionRole.find_each do |role|
      existing = Array(role.permissions)
      renamed  = existing.map { |p| RENAMES.fetch(p, p) }
      next if renamed == existing

      # Also rename keys in permission_scopes (scope settings travel with the permission)
      old_scopes = role.permission_scopes || {}
      new_scopes = old_scopes.transform_keys { |k| RENAMES.fetch(k, k) }

      role.update_columns(
        permissions:       renamed,
        permission_scopes: new_scopes
      )
      say "Renamed permissions in '#{role.name}' (id=#{role.id}): #{(existing & RENAMES.keys).join(', ')}"
    end
  end

  def down
    inverse = RENAMES.invert

    PermissionRole.find_each do |role|
      existing = Array(role.permissions)
      restored = existing.map { |p| inverse.fetch(p, p) }
      next if restored == existing

      old_scopes = role.permission_scopes || {}
      restored_scopes = old_scopes.transform_keys { |k| inverse.fetch(k, k) }

      role.update_columns(
        permissions:       restored,
        permission_scopes: restored_scopes
      )
    end
  end
end
