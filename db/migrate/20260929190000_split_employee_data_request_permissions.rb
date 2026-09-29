# Employee Add Requests moved from one catch-all reviewer permission
# (review_employee_data_requests) to explicit per-action permissions. Any role
# that already held the old permission gets the equivalent explicit set, so
# nobody silently loses (or gains) access — and the role stays valid, since
# PermissionRole rejects unknown permission names.
class SplitEmployeeDataRequestPermissions < ActiveRecord::Migration[8.1]
  OLD = "review_employee_data_requests".freeze
  NEW = %w[
    view_employee_requests view_all_employee_requests review_employee_requests
    approve_employee_requests reject_employee_requests request_employee_changes
  ].freeze

  class Role < ActiveRecord::Base
    self.table_name = "permission_roles"
  end

  def up
    Role.where("permissions ? :old", old: OLD).find_each do |role|
      role.update_columns(permissions: (Array(role.permissions) - [ OLD ] + NEW).uniq,
                          permission_scopes: (role.permission_scopes || {}).except(OLD))
    end
  end

  def down
    Role.where("permissions ? :perm", perm: "review_employee_requests").find_each do |role|
      role.update_columns(permissions: (Array(role.permissions) - NEW + [ OLD ]).uniq)
    end
  end
end
