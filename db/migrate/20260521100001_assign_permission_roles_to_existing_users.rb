class AssignPermissionRolesToExistingUsers < ActiveRecord::Migration[8.1]
  ROLE_PERMISSION_MAP = {
    "branch_manager" => {
      name: "Branch Manager",
      permissions: %w[view_employees manage_employees view_attendance manage_attendance
                      view_payroll manage_payroll view_requests approve_requests
                      assign_shifts view_shifts manage_adjustments]
    },
    "area_manager" => {
      name: "Area Manager",
      permissions: %w[view_employees view_attendance view_payroll finalize_payroll
                      view_requests approve_requests view_shifts manage_adjustments
                      approve_adjustments]
    },
    "accountant" => {
      name: "Finance",
      permissions: %w[view_payroll manage_payroll view_requests pay_advances
                      view_reports export_reports]
    }
  }.freeze

  def up
    Business.find_each do |business|
      ROLE_PERMISSION_MAP.each do |role, attrs|
        next unless business.users.where(role: role).exists?

        permission_role = business.permission_roles.find_or_create_by!(name: attrs[:name]) do |pr|
          pr.permissions = attrs[:permissions]
        end

        business.users.where(role: role, permission_role_id: nil)
                .update_all(permission_role_id: permission_role.id)
      end
    end

    User.where.not(role: "super_admin").update_all(role: "employee")
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
