class SplitViewPerformancePermission < ActiveRecord::Migration[8.0]
  # view_performance was a single permission covering dashboard, notes (observations),
  # monthly reviews, and reports. It is replaced by four independent permissions so
  # each section can be granted or withheld independently.
  OLD_PERM = "view_performance"
  NEW_PERMS = %w[view_performance_dashboard view_notes view_monthly_reviews view_performance_reports].freeze

  def up
    PermissionRole.find_each do |role|
      perms  = Array(role.permissions)
      scopes = Hash(role.permission_scopes)

      next unless perms.include?(OLD_PERM)

      old_scope = scopes[OLD_PERM]

      new_perms  = (perms - [OLD_PERM] + NEW_PERMS).uniq
      new_scopes = scopes.except(OLD_PERM)
      NEW_PERMS.each { |p| new_scopes[p] = old_scope if old_scope.present? }

      role.update_columns(permissions: new_perms, permission_scopes: new_scopes)
    end
  end

  def down
    PermissionRole.find_each do |role|
      perms  = Array(role.permissions)
      scopes = Hash(role.permission_scopes)

      next unless (perms & NEW_PERMS).any?

      old_scope = NEW_PERMS.filter_map { |p| scopes[p] }.first

      new_perms  = (perms - NEW_PERMS + [OLD_PERM]).uniq
      new_scopes = scopes.except(*NEW_PERMS)
      new_scopes[OLD_PERM] = old_scope if old_scope.present?

      role.update_columns(permissions: new_perms, permission_scopes: new_scopes)
    end
  end
end
